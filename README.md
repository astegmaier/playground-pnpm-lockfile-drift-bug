# pnpm `install`-vs-`dedupe` optional-peer lockfile drift

A **minimal, deterministic** reproduction of a pnpm bug where `pnpm install` and
`pnpm dedupe`, run on the **same** edited project, produce **different**
`pnpm-lock.yaml` files — specifically, `install` spuriously propagates an
**optional** transitive peer dependency (`supports-color`, the optional peer of
`debug`) onto packages that are completely unrelated to the edit.

This is the small-scale, faithful version of the lockfile churn seen in the
a large monorepo at Microsoft, where removing a single internal
library from two manifests and running `pnpm install`
rewrote **417 lockfile lines** — 134 unrelated packages gaining a
`(supports-color@5.5.0)` suffix — that `pnpm dedupe` would not have produced.

Reproduces with the current **`pnpm@11.9.0`**.

---

## Repro Steps

The project is a single package with three real npm dependencies:

package.json

```jsonc
{
  "name": "playground-pnpm-lockfile-drift-bug",
  "dependencies": {
    "nodemon": "3.1.0",
    "simple-git": "3.36.0",
    "tiny-invariant": "1.3.3"
  }
}
```

node_modules/.pnpm/nodemon@3.1.0/node_modules/nodemon/package.json

```jsonc
{
  "name": "nodemon",
  "version": "3.1.0",
  "dependencies": {
    "debug": "^4",
    "supports-color": "^5.5.0"
    // ...
  },
  // ...
}
```

node_modules/.pnpm/debug@4.4.3_supports-color@5.5.0/node_modules/debug/package.json

```jsonc
{
  "name": "debug",
  "version": "4.4.3",
  "peerDependenciesMeta": {
    "supports-color": {
      "optional": true
    }
  },
  // ...
}
```

node_modules/.pnpm/simple-git@3.36.0/node_modules/simple-git/package.json

```jsonc
{
  "name": "simple-git",
  "version": "3.36.0",
  "dependencies": {
    "debug": "^4.4.0"
    // ...
  }
  // ...
}
```

`nodemon` is the one package that pulls in both `supports-color@5.5.0` and `debug`,
so it is where the optional peer is legitimately bound. `simple-git` is an
**unrelated** `debug` consumer — its `debug` is **plain** in the committed lockfile.

`./scripts/reproduce.sh` runs these steps for you:

**1. Remove the unrelated dependency** — delete the `"tiny-invariant": "1.3.3"`
line from `package.json`.

**2. Install.** `simple-git` wrongly gains a `(supports-color@5.5.0)` suffix:

```bash
pnpm install
grep -c 'supports-color@5.5.0)' pnpm-lock.yaml   # was 4, now 8
grep 'simple-git@3.36.0(' pnpm-lock.yaml         # simple-git@3.36.0(supports-color@5.5.0):
```

**3. Dedupe.** It removes the suffix `install` just added — proving it was spurious:

```bash
pnpm dedupe
grep -c 'supports-color@5.5.0)' pnpm-lock.yaml   # back to 4
grep 'simple-git@3.36.0(' pnpm-lock.yaml         # (nothing — plain again)
```

Removing `tiny-invariant` has nothing to do with `simple-git`, yet `pnpm install`
suffixes it and `pnpm dedupe` does not. That disagreement is the bug. (Without the
edit, `pnpm install` changes nothing — the lockfile is a fixed point; only the edit
triggers the drift, exactly the office-bohemia symptom.)

---

## Root cause

`pnpm install` reuses the **previous lockfile's per-package `dependencies` /
`optionalDependencies` blocks** during re-resolution; `pnpm dedupe` throws them
away first. For an *optional* peer, keeping those blocks re-propagates the peer
onto additional (deeper) consumers.

The two relevant pieces of pnpm source (paths relative to the pnpm repo,
`installing/deps-resolver` & `installing/deps-installer`):

1. **`deps-resolver/src/resolveDependencies.ts`** (`resolveChildren`):

   ```ts
   const currentResolvedDependencies = (dependencyLockfile != null)
     ? {
       ...dependencyLockfile.dependencies,
       ...dependencyLockfile.optionalDependencies,   // includes  supports-color: 5.5.0
     }
     : undefined
   const resolvedDependencies = parentPkg.updated ? undefined : currentResolvedDependencies
   // ...passed as  preferredDependencies: currentResolvedDependencies  and  resolvedDependencies
   ```

   The preserved `optionalDependencies` (the bound `supports-color`) make the
   provider visible to additional `debug` occurrences during the re-resolution,
   so they bind the optional peer too → the suffix propagates up to their
   ancestors (`simple-git`, `@kwsites/file-exists`, and in office-bohemia
   `jest-environment-jsdom`, `jsdom`, `webpack-dev-server`, `madge`, `spdy`, …).

2. **`deps-installer/src/install/index.ts`** — `pnpm dedupe` sets `dedupe: true`,
   which calls **`forgetResolutionsOfAllPrevWantedDeps`**:

   ```ts
   // clear every PackageSnapshot's dependencies / optionalDependencies so the
   // newly resolved deps are always used
   wantedLockfile.packages = mapValues(
     ({ dependencies, optionalDependencies, ...rest }) => rest,
     wantedLockfile.packages)
   ```

   This deletes the blocks that piece #1 would otherwise reuse, so `dedupe`'s
   fresh resolution binds the optional peer only where it is genuinely visible —
   the minimal, canonical set.

### Proof (instrumented pnpm)

Gating piece #1 behind an env flag that forces `currentResolvedDependencies =
undefined` (i.e. making `install` behave like `dedupe`'s `forgetResolutions`)
collapses the drift exactly:

| run (canonical + edit) | suffix positions |
| --- | --- |
| `pnpm install` | **8** |
| `pnpm install` with `currentResolvedDependencies` forced `undefined` | **4** |
| `pnpm dedupe` | 4 |

The identical experiment in office-bohemia gives **200 → 66** (and `dedupe` → 66).
Same code path, same fix.

---

## Practical consequence

A committed `pnpm dedupe`-stable lockfile cannot be maintained with `pnpm install`
alone: any manifest edit makes `install` re-propagate optional peers onto unrelated
packages, and only a follow-up `pnpm dedupe` removes the churn. The drift is
**deterministic** (not a timing race) and specific to **optional** peer dependencies
— a genuine `install`-vs-`dedupe` disagreement, where each command is internally
stable but the two produce different lockfiles from the same input.

---

## Files

| path | purpose |
| --- | --- |
| `package.json` | the single-package manifest (three real deps) |
| `canonical/pnpm-lock.yaml` | the committed, `dedupe`-stable reference lockfile |
| `pnpm-lock.yaml` | working copy (kept equal to the canonical reference) |
| `scripts/reproduce.sh` | runs the install-vs-dedupe comparison end to end |

## Notes

- **Real registry packages are required.** Workspace/`file:` packages are symlinked
  singletons and never get the per-context peer-dependency *duplication* the bug
  needs, so it cannot be reproduced with a purely synthetic, link-only workspace.
- `node_modules/` is git-ignored.
- `PM="pd" ./scripts/reproduce.sh` runs the repro against a custom pnpm binary
  (e.g. a different pnpm build) instead of the pinned `pnpm@11.9.0`.

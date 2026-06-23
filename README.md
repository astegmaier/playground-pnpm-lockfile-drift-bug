# pnpm `install`-vs-`dedupe` optional-peer lockfile drift

A **minimal, deterministic** reproduction of a pnpm bug where `pnpm install` and
`pnpm dedupe`, run on the **same** edited workspace, produce **different**
`pnpm-lock.yaml` files — specifically, `install` spuriously propagates an
**optional** transitive peer dependency (`supports-color`, the optional peer of
`debug`) onto packages that are completely unrelated to the edit.

This is the small-scale, faithful version of the lockfile churn seen in the
[office-bohemia](../office-bohemia4) monorepo, where removing a single internal
library (`@fluidx/localize-js`) from two manifests and running `pnpm install`
rewrote **417 lockfile lines** — 134 unrelated packages gaining a
`(supports-color@5.5.0)` suffix — that `pnpm dedupe` would not have produced.

Reproduces with **stock `pnpm@11.8.0`** (no fork or patch required).

---

## Repro Steps

The workspace is two packages with three real npm dependencies:

```
packages/main   →  nodemon@3.1.0   simple-git@3.36.0   @repro/extra
packages/extra  →  chalk@2.4.2
```

`nodemon` is the one package that pulls in both `supports-color@5.5.0` and `debug`,
so it is where the optional peer is legitimately bound. `simple-git` is an
**unrelated** `debug` consumer — its `debug` is **plain** in the committed lockfile.

Requires `pnpm@11.8.0` (pinned via `packageManager`; run `corepack enable` once).
`./scripts/reproduce.sh` runs these steps for you:

**1. Remove the unrelated dependency** — delete the `"@repro/extra": "workspace:*"`
line from `packages/main/package.json`.

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

Removing `@repro/extra` has nothing to do with `simple-git`, yet `pnpm install`
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

## Relationship to other pnpm peer-suffix fixes

This is **distinct from** and **not fixed by**
[pnpm #12179](https://github.com/pnpm/pnpm/pull/12179) /
[#12514](https://github.com/pnpm/pnpm/pull/12514), which address *required*-peer
suffix churn / `dedupe` completion-order races. This bug:

- is **deterministic** (not a timing race),
- is about an **optional** transitive peer,
- is a genuine **`install` vs `dedupe` disagreement** (each is internally stable),
- reproduces on stock `pnpm@11.8.0` **and** on a local build that already contains
  #12514.

The practical consequence for a monorepo: a committed `pnpm dedupe`-stable
lockfile cannot be maintained with `pnpm install` alone — any manifest edit makes
`install` re-propagate optional peers, and only a follow-up `pnpm dedupe` removes
the churn.

---

## Files

| path | purpose |
| --- | --- |
| `packages/main`, `packages/extra` | the two-package workspace |
| `canonical/pnpm-lock.yaml` | the committed, `dedupe`-stable reference lockfile |
| `pnpm-lock.yaml` | working copy (kept equal to the canonical reference) |
| `scripts/reproduce.sh` | runs the install-vs-dedupe comparison end to end |

## Notes

- **Real registry packages are required.** Workspace/`file:` packages are symlinked
  singletons and never get the per-context peer-dependency *duplication* the bug
  needs, so it cannot be reproduced with a purely synthetic, link-only workspace.
- `node_modules/` is git-ignored.
- `PM="pd" ./scripts/reproduce.sh` runs the repro against a custom pnpm binary
  (e.g. a local fork build) instead of the pinned `pnpm@11.8.0`.

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

### The workspace (2 packages, 3 real npm deps)

```
packages/main/package.json
    nodemon@3.1.0        PROVIDER  — deps BOTH supports-color@5.5.0 AND debug, so its
                                     debug legitimately binds the optional peer and seeds
                                     supports-color into the snapshot optionalDependencies blocks
    simple-git@3.36.0    CONSUMER  — an innocent debug user; its debug (and its dep
                                     @kwsites/file-exists) is PLAIN in the canonical lockfile
    @repro/extra         TRIGGER   — workspace dep that is REMOVED to perturb the graph

packages/extra/package.json
    chalk@2.4.2          a SECOND supports-color@5.5.0 provider
```

`canonical/pnpm-lock.yaml` is the committed, `pnpm dedupe`-stable reference; the
working `pnpm-lock.yaml` starts equal to it.

> **Real registry packages are required.** Workspace/`file:` packages are symlinked
> singletons and never get the per-context peer-dependency *duplication* the bug
> needs — so this cannot be reproduced with a purely synthetic, link-only workspace.
> `nodemon`/`simple-git` are materialized per peer-context in the virtual store,
> which is what lets the optional-peer suffix drift.

### Run it (from the repo root)

`./scripts/reproduce.sh` does everything below automatically. The manual steps,
spelled out:

```bash
# 0. Pin pnpm 11.8.0 (the repo's packageManager). Reproduces on stock pnpm — no fork needed.
corepack enable

# 1. Start from the canonical, dedupe-stable lockfile.
cp canonical/pnpm-lock.yaml pnpm-lock.yaml

# 2. BASELINE — a no-edit install changes nothing (the lockfile is a fixed point).
pnpm install --lockfile-only
diff canonical/pnpm-lock.yaml pnpm-lock.yaml && echo "0 churn"   # identical
grep -c 'supports-color@5.5.0)' pnpm-lock.yaml                   # => 4

# 3. THE EDIT — remove the @repro/extra workspace dependency from packages/main.
#    By hand: delete the  "@repro/extra": "workspace:*"  line in packages/main/package.json
#    …or run:
( cd packages/main && npm pkg delete 'dependencies.@repro/extra' )

# 4. pnpm INSTALL on (canonical + edit).
cp canonical/pnpm-lock.yaml pnpm-lock.yaml
pnpm install --lockfile-only
grep -c 'supports-color@5.5.0)' pnpm-lock.yaml                   # => 8   <-- BUG (over-propagated)
cp pnpm-lock.yaml /tmp/install.yaml                             # keep for the diff below

# 5. pnpm DEDUPE on the SAME (canonical + edit) input. Reset the lockfile first!
cp canonical/pnpm-lock.yaml pnpm-lock.yaml
pnpm dedupe
grep -c 'supports-color@5.5.0)' pnpm-lock.yaml                   # => 4   <-- correct / minimal

# 6. Restore the working tree when done.
( cd packages/main && npm pkg set 'dependencies.@repro/extra=workspace:*' )
cp canonical/pnpm-lock.yaml pnpm-lock.yaml
```

### What to look for (the bug)

Step 4 (`install`) produces **8** `supports-color@5.5.0` suffix positions; step 5
(`dedupe`) produces **4** — from the *same* edited input. The 4 extra are on
`simple-git` and `@kwsites/file-exists`, which are **completely unrelated** to the
removed `@repro/extra`. Diff the two lockfiles to see `install` spuriously
suffixing them:

```bash
diff /tmp/install.yaml pnpm-lock.yaml      # install (left) vs dedupe (right)
```

```diff
-         version: 3.36.0(supports-color@5.5.0)     # install: simple-git suffixed
+         version: 3.36.0                           # dedupe:  plain
-   '@kwsites/file-exists@1.1.1(supports-color@5.5.0)':
+   '@kwsites/file-exists@1.1.1':
-   simple-git@3.36.0(supports-color@5.5.0):
+   simple-git@3.36.0:
```

**The bug:** `install` and `dedupe` produce different lockfiles from identical
input, and removing an unrelated dependency *adds* peer suffixes under `install`.
Note the baseline (step 2): without the edit, `install` is a 0-churn fixed point —
only the manifest edit exposes the disagreement, exactly the office-bohemia symptom.

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

- `node_modules/` is git-ignored; `--lockfile-only` is used so no packages are
  linked.
- `PM="pd" ./scripts/reproduce.sh` runs the repro against a custom pnpm binary
  (e.g. a local fork build) instead of the pinned `pnpm@11.8.0`.

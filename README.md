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

## TL;DR

| step (on the committed, `dedupe`-stable lockfile) | `supports-color@5.5.0` suffix positions |
| --- | --- |
| canonical / committed (produced by `pnpm dedupe`) | **4** |
| no-edit `pnpm install` | 4 (0 churn — stable fixed point) |
| **remove one workspace dep, then `pnpm install`** | **8** ← spurious over-propagation |
| remove the same dep, then `pnpm dedupe` | **4** (correct, minimal) |

`install` and `dedupe` disagree. The 4 extra suffix positions are on
`simple-git` and `@kwsites/file-exists`, which have **nothing** to do with the
removed dependency.

```bash
corepack enable      # so `pnpm` resolves to the pinned pnpm@11.8.0
./scripts/reproduce.sh
```

Expected tail:

```
==> 3. RESULT
    >>> BUG REPRODUCED: install (8) != dedupe (4)
    >>> Packages that 'pnpm install' spuriously suffixed (absent from dedupe):
               version: 3.36.0(supports-color@5.5.0)
             '@kwsites/file-exists': 1.1.1(supports-color@5.5.0)
         '@kwsites/file-exists@1.1.1(supports-color@5.5.0)':
         simple-git@3.36.0(supports-color@5.5.0):
```

---

## The workspace

Two workspace packages and three real npm dependencies:

```
packages/main/package.json
    nodemon@3.1.0        ← the supports-color@5.5.0 PROVIDER
    simple-git@3.36.0    ← an innocent debug CONSUMER (plain in the canonical form)
    @repro/extra         ← workspace dep that is REMOVED to trigger the bug

packages/extra/package.json
    chalk@2.4.2          ← a SECOND supports-color@5.5.0 provider
```

Why each package matters:

- **`nodemon@3.1.0`** depends on **both** `supports-color@5.5.0` *and* `debug`.
  Because `supports-color` is a direct sibling of `debug` inside nodemon, nodemon's
  `debug` legitimately binds the optional peer → `debug@4.4.3(supports-color@5.5.0)`.
  This is what seeds `supports-color@5.5.0` into the lockfile, both as a package
  and as a **bound optional peer** recorded in snapshot `optionalDependencies`
  blocks.
- **`simple-git@3.36.0`** (and its dep `@kwsites/file-exists`) are ordinary `debug`
  consumers. In the canonical (`dedupe`) lockfile their `debug` is **plain** —
  `supports-color` is *not* in their resolution context.
- **`chalk@2.4.2`** (reached via `@repro/extra`) is a second provider of
  `supports-color@5.5.0`. Removing `@repro/extra` is the graph perturbation.

> **Real npm packages are required.** Workspace/`file:` packages are symlinked
> singletons, so they never get the per-context peer-dependency *duplication* that
> the bug needs. Registry packages (`nodemon`, `simple-git`, …) are materialized
> per peer-context in the virtual store, which is what makes the optional-peer
> suffix able to drift. This is why the bug **cannot** be reproduced with a
> purely synthetic, link-only workspace.

---

## What the bug looks like

Removing `@repro/extra` (i.e. `chalk@2.4.2`) is unrelated to `simple-git`. Yet
`pnpm install` adds a `(supports-color@5.5.0)` suffix to it, while `pnpm dedupe`
on the identical input does not:

```diff
# pnpm-lock.yaml after `pnpm install` (left = dedupe/correct, right = install/buggy)
-         version: 3.36.0
+         version: 3.36.0(supports-color@5.5.0)
-   '@kwsites/file-exists@1.1.1':
+   '@kwsites/file-exists@1.1.1(supports-color@5.5.0)':
-   simple-git@3.36.0:
+   simple-git@3.36.0(supports-color@5.5.0):
```

Both lockfiles are *install fixed points* (hysteresis): a no-edit `pnpm install`
reproduces the committed lockfile with **0 churn**. Only a manifest edit forces
the re-resolution that exposes the install-vs-dedupe disagreement — exactly the
office-bohemia symptom.

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

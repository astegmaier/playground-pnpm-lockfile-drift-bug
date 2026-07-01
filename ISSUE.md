> **Suggested title:** Regression (since 11.5.2): `pnpm install` over-propagates an optional transitive peer onto unrelated packages after a manifest edit — disagreeing with `pnpm dedupe`

### Last pnpm version that worked

11.5.1

### pnpm version

11.9.0 (still reproduces in the latest release)

### Code to reproduce the issue

Minimal reproduction: https://github.com/astegmaier/playground-pnpm-lockfile-drift-bug

A tiny pnpm workspace with two packages, `a` and `b` (the root `package.json` is empty). Every `dependencies` / `peerDependencies` edge between the packages — solid arrows are `dependencies` (labelled with the version range), the dashed arrow is `debug`'s **optional** `supports-color` peer:

```mermaid
flowchart TD
  a -->|"workspace:*"| b
  a -->|"6.0.2"| ab["agent-base"]
  a -->|"1.3.3"| ti["tiny-invariant"]
  b -->|"4.4.3"| dbg["debug"]
  b -->|"5.5.0"| sc["supports-color"]
  ab -->|"4"| dbg
  dbg -. "peer (optional)" .-> sc
```

The lockfile produced for this monorepo by the initial `pnpm install` has a snapshot for `agent-base` that looks like this:

```yaml
  agent-base@6.0.2:
    dependencies:
      debug: 4.4.3(supports-color@5.5.0)
    transitivePeerDependencies:
      - supports-color
```

Steps:

1. Remove the `"tiny-invariant": "1.3.3"` dependency from `a/package.json`.
2. Run `pnpm install`. Now the lockfile snapshot for `agent-base` has a **peer suffix**:

    ```yaml
      agent-base@6.0.2(supports-color@5.5.0): ## <-- BUG: the peer suffix is incorrectly added
        dependencies:
          debug: 4.4.3(supports-color@5.5.0)
        transitivePeerDependencies:
          - supports-color
    ```

3. Run `pnpm dedupe` — the suffix is (correctly) **removed** again.

`./scripts/reproduce.sh` in the repro runs these steps end to end.

### Expected behavior

`pnpm install` should produce the same lockfile as `pnpm dedupe` for the same input — and, in particular, should not add a peer suffix to packages that are unrelated to the edit. A committed `pnpm dedupe`-stable lockfile should stay stable across `pnpm install` after manifest edits, instead of re-propagating optional peers that `pnpm dedupe` then removes.

This is how it worked before the regression: on 11.5.1 and earlier, `pnpm install` and `pnpm dedupe` agree, and removing `tiny-invariant` leaves `agent-base` untouched.

### Actual behavior

`pnpm install` and `pnpm dedupe` produce **different** lockfiles from the same project. Removing one dependency (`tiny-invariant`) that has nothing to do with `agent-base` and running `pnpm install` propagates the optional `supports-color` peer onto `agent-base` — it gains a `(supports-color@5.5.0)` suffix and a second snapshot. `pnpm dedupe` on the identical input does not. In `agent-base`'s snapshot, `supports-color` stays a `transitivePeerDependency` either way; `install` additionally hoists it into the package's own peer suffix, where `dedupe` keeps it absorbed.

The drift is **deterministic** (not a timing race) and surfaces only on re-resolution: a no-edit `pnpm install` reproduces the committed lockfile with 0 churn, so both forms are install fixed points — but any manifest edit forces `install` to re-propagate the optional peer. The practical consequence is that a committed, `pnpm dedupe`-stable lockfile **cannot be maintained with `pnpm install` alone**: every manifest edit re-introduces optional-peer churn on unrelated packages (in a large monorepo this was ~130 packages / hundreds of lines), and only a follow-up `pnpm dedupe` removes it.

### Additional information

**Regression range.** Bisected with corepack over the lockfile-v9 range:

- ✅ **11.5.1** — last good (`install` and `dedupe` agree)
- ❌ **11.5.2** — first bad (regression appears; still present through the current **11.9.0**)

**Likely responsible change:** [#12083](https://github.com/pnpm/pnpm/pull/12083) — *"fix(deps-resolver): prefer locked peer contexts during resolution by default"* (commit `1c73e8303c`), the only peer-resolver change in the `v11.5.1..v11.5.2` range and the first bullet of the [11.5.2 release notes](https://github.com/pnpm/pnpm/releases/tag/v11.5.2). It makes a writable `pnpm install` reuse the peer contexts already recorded in the lockfile; for an *optional* peer that re-propagates the provider onto additional consumers.

**Root cause detail.** `pnpm install` reuses the previous lockfile's per-package `dependencies`/`optionalDependencies` blocks during re-resolution (`currentResolvedDependencies` in `resolveChildren`, `installing/deps-resolver/src/resolveDependencies.ts`), feeding the already-bound optional peer back in and re-propagating it. `pnpm dedupe` first clears those blocks via `forgetResolutionsOfAllPrevWantedDeps` (`installing/deps-installer/src/install/index.ts`), so it binds the optional peer only where genuinely visible. Forcing `currentResolvedDependencies = undefined` in `install` makes it match `dedupe` exactly.

**Repro note.** The **victim** must be a real registry package — the bug duplicates its snapshot (`agent-base@6.0.2` → `agent-base@6.0.2(supports-color@5.5.0)`), and workspace importers (symlinked singletons) never get that per-context peer suffix. The **binder** can be a local workspace package, since its only role is to nest `debug`+`supports-color` so the bound `debug@4.4.3(supports-color@5.5.0)` snapshot exists.

### Node.js version

24.16.0

### Operating System

- [x] macOS
- [ ] Windows
- [ ] Linux

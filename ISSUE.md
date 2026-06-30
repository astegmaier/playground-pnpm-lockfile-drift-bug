> **Suggested title:** `pnpm install` and `pnpm dedupe` disagree — `install` over-propagates an optional transitive peer onto unrelated packages after a manifest edit

### Verify latest release

- [x] I verified that the issue exists in the latest pnpm release

### pnpm version

11.9.0

### Which area(s) of pnpm are affected? (leave empty if unsure)

Peer dependency resolution / lockfile (`pnpm install` vs `pnpm dedupe`)

### Link to the code that reproduces this issue or a replay of the bug

https://github.com/astegmaier/playground-pnpm-lockfile-drift-bug

### Reproduction steps

A two-package workspace with three real npm dependencies.

#### `pnpm-workspace.yaml`

```yaml
packages:
  - 'packages/*'
```

#### `packages/main/package.json`

```json
{
  "name": "@repro/main",
  "dependencies": {
    "nodemon": "3.1.0",
    "simple-git": "3.36.0",
    "@repro/extra": "workspace:*"
  }
}
```

#### `packages/extra/package.json`

```json
{
  "name": "@repro/extra",
  "dependencies": {
    "chalk": "2.4.2"
  }
}
```

#### The relevant real-package relationship

`debug` declares `supports-color` as an **optional** peer:

```json
{
  "name": "debug",
  "peerDependencies": { "supports-color": "*" },
  "peerDependenciesMeta": { "supports-color": { "optional": true } }
}
```

`supports-color@5.5.0` is provided by two packages in the graph:

- `nodemon@3.1.0` depends on **both** `debug` and `supports-color@5.5.0`, so its `debug` legitimately binds the optional peer (`debug@4.4.3(supports-color@5.5.0)`).
- `chalk@2.4.2` (reached only via `@repro/extra`) also depends on `supports-color@5.5.0`.

`simple-git@3.36.0` (and its dependency `@kwsites/file-exists`) are ordinary `debug` consumers, completely unrelated to `@repro/extra`.

#### Steps

The committed `pnpm-lock.yaml` is `pnpm dedupe`-stable. Then:

1. `pnpm install` — no change (the lockfile is a fixed point; `simple-git` is plain).
2. Remove the `"@repro/extra": "workspace:*"` line from `packages/main/package.json`.
3. `pnpm install` — `simple-git` (unrelated to the edit) **gains** a `(supports-color@5.5.0)` suffix.
4. `pnpm dedupe` — the suffix is **removed** again.

(`./scripts/reproduce.sh` in the repo runs steps 1–4 automatically.)

#### Actual `pnpm-lock.yaml` (after step 3, `pnpm install`)

```yaml
importers:
  packages/main:
    dependencies:
      simple-git:
        specifier: 3.36.0
        version: 3.36.0(supports-color@5.5.0)   # <-- install added the optional-peer suffix

snapshots:
  simple-git@3.36.0(supports-color@5.5.0):       # <-- and a second, suffixed snapshot
    dependencies:
      '@kwsites/file-exists': 1.1.1(supports-color@5.5.0)
      debug: 4.4.3(supports-color@5.5.0)
      # ...
    transitivePeerDependencies:
      - supports-color
```

#### Expected `pnpm-lock.yaml` (what `pnpm dedupe` produces from the same input — step 4)

```yaml
importers:
  packages/main:
    dependencies:
      simple-git:
        specifier: 3.36.0
        version: 3.36.0

snapshots:
  simple-git@3.36.0:
    dependencies:
      '@kwsites/file-exists': 1.1.1
      debug: 4.4.3(supports-color@5.5.0)
      # ...
    transitivePeerDependencies:
      - supports-color
```

### Describe the Bug

`pnpm install` and `pnpm dedupe` produce **different** lockfiles from the same workspace. Removing one dependency (`@repro/extra`) that has nothing to do with `simple-git` and running `pnpm install` propagates the optional `supports-color` peer onto `simple-git` and `@kwsites/file-exists` — they gain a `(supports-color@5.5.0)` suffix and a second snapshot. `pnpm dedupe` on the identical input does not. In `simple-git`'s snapshot, `supports-color` stays a `transitivePeerDependency` either way; `install` additionally hoists it into the package's own peer suffix, where `dedupe` keeps it absorbed.

The drift is **deterministic** (not a timing race) and surfaces only on re-resolution: a no-edit `pnpm install` reproduces the committed lockfile with 0 churn, so both forms are install fixed points — but any manifest edit forces `install` to re-propagate the optional peer. The practical consequence is that a committed, `pnpm dedupe`-stable lockfile **cannot be maintained with `pnpm install` alone**: every manifest edit re-introduces optional-peer churn on unrelated packages (in a large monorepo this was ~130 packages / hundreds of lines), and only a follow-up `pnpm dedupe` removes it.

Root cause appears to be that `pnpm install` reuses the previous lockfile's per-package `dependencies`/`optionalDependencies` blocks during re-resolution (`currentResolvedDependencies` in `resolveChildren`, `installing/deps-resolver/src/resolveDependencies.ts`), feeding the already-bound optional peer back in and re-propagating it onto additional consumers. `pnpm dedupe` first clears those blocks via `forgetResolutionsOfAllPrevWantedDeps` (`installing/deps-installer/src/install/index.ts`), so it binds the optional peer only where genuinely visible. Forcing `currentResolvedDependencies = undefined` in `install` makes it match `dedupe` exactly.

Note: this only reproduces with **real registry packages** — workspace/`file:` packages are symlinked singletons and never get the per-context peer duplication the bug needs.

### Expected Behavior

`pnpm install` should produce the same lockfile as `pnpm dedupe` for the same input — and, in particular, should not add a peer suffix to packages that are unrelated to the edit. A committed `pnpm dedupe`-stable lockfile should stay stable across `pnpm install` after manifest edits, instead of re-propagating optional peers that `pnpm dedupe` then removes.

### Which Node.js version are you using?

24.16.0

### Which operating systems have you used?

- [x] macOS
- [ ] Windows
- [ ] Linux

### If your OS is a Linux based, which one it is? (Include the version if relevant)

_No response_

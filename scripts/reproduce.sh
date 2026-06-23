#!/usr/bin/env bash
#
# Reproduce the pnpm install-vs-dedupe optional-peer lockfile drift.
#
# Starting from the canonical (`pnpm dedupe`-stable) lockfile, removing ONE
# unrelated workspace dependency and running `pnpm install` adds a spurious
# `(supports-color@5.5.0)` suffix to `simple-git` (and `@kwsites/file-exists`).
# `pnpm dedupe` then removes it again — proving `install` and `dedupe` disagree.
#
# Usage:  ./scripts/reproduce.sh           # uses package.json `packageManager` (pnpm@11.8.0) via corepack
#         PM="pd" ./scripts/reproduce.sh   # use a custom pnpm binary (e.g. a local fork build)
set -uo pipefail
cd "$(dirname "$0")/.."
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

PM="${PM:-pnpm}"
TOK='supports-color@5.5.0)'
MAIN='packages/main/package.json'
count() { grep -c "$TOK" pnpm-lock.yaml 2>/dev/null | head -1; }

# back up the working tree so we can restore it byte-for-byte afterwards
BAK="$(mktemp -d)"; cp "$MAIN" "$BAK/main.json"; cp pnpm-lock.yaml "$BAK/lock.yaml"
restore() { cp "$BAK/main.json" "$MAIN"; cp "$BAK/lock.yaml" pnpm-lock.yaml;
            find . -name node_modules -type d -not -path './.git/*' -exec rm -rf {} + 2>/dev/null; rm -rf "$BAK"; }
trap restore EXIT

echo "Using $PM $($PM --version);  canonical suffix positions: $(count)"

echo "==> 1. remove the unrelated dependency @repro/extra from packages/main"
node -e "const f='$MAIN',j=require('./'+f);delete j.dependencies['@repro/extra'];require('fs').writeFileSync(f,JSON.stringify(j,null,2)+'\n')"

echo "==> 2. pnpm install"
$PM install >/dev/null 2>&1
INSTALL=$(count)
echo "    suffix positions: $INSTALL    $(grep -o 'simple-git@3.36.0(supports-color@5.5.0)' pnpm-lock.yaml | head -1)"

echo "==> 3. pnpm dedupe"
$PM dedupe >/dev/null 2>&1
DEDUPE=$(count)
echo "    suffix positions: $DEDUPE"

echo
if [ "$INSTALL" = "8" ] && [ "$DEDUPE" = "4" ]; then
  echo ">>> BUG REPRODUCED: install added supports-color to simple-git ($INSTALL positions); dedupe removed it ($DEDUPE)."
else
  echo ">>> install=$INSTALL dedupe=$DEDUPE (expected 8 then 4)"
fi

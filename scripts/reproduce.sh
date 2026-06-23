#!/usr/bin/env bash
#
# Reproduce the pnpm install-vs-dedupe optional-peer lockfile drift.
#
# From the canonical (`pnpm dedupe`-stable) lockfile in `canonical/pnpm-lock.yaml`,
# removing ONE workspace dependency and running `pnpm install` adds a
# `(supports-color@5.5.0)` optional-peer suffix to UNRELATED packages (simple-git,
# @kwsites/file-exists). `pnpm dedupe` on the exact same edited input does NOT --
# proving install and dedupe disagree on optional-peer propagation.
#
# Usage:  ./scripts/reproduce.sh           # uses package.json `packageManager` (pnpm@11.8.0) via corepack
#         PM="pd" ./scripts/reproduce.sh   # use a custom pnpm binary (e.g. a local fork build)
set -uo pipefail
cd "$(dirname "$0")/.."
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

PM="${PM:-pnpm}"
TOK='supports-color@5.5.0)'
MAIN='packages/main/package.json'
EDIT_DEP='@repro/extra'
CANON='canonical/pnpm-lock.yaml'

count() { grep -c "$TOK" pnpm-lock.yaml 2>/dev/null | head -1; }
reset_lock() { cp "$CANON" pnpm-lock.yaml; }
restore_main() { node -e "const f='$MAIN';const j=require('./'+f);j.dependencies['$EDIT_DEP']='workspace:*';require('fs').writeFileSync(f,JSON.stringify(j,null,2)+'\n')"; }
remove_dep() { node -e "const f='$MAIN';const j=require('./'+f);delete j.dependencies['$EDIT_DEP'];require('fs').writeFileSync(f,JSON.stringify(j,null,2)+'\n')"; }

echo "Using package manager: $PM ($($PM --version))"
echo

echo "==> 0. Baseline: the canonical lockfile is a no-op install fixed point"
restore_main; reset_lock; rm -rf node_modules
$PM install --lockfile-only >/dev/null 2>&1
echo "    canonical supports-color suffix positions: $(count)"
if diff -q "$CANON" pnpm-lock.yaml >/dev/null; then echo "    no-edit install: 0 churn (stable) [ok]"; else echo "    WARNING: not install-stable on this toolchain"; fi

echo
echo "==> 1. Apply the edit: remove workspace dep '$EDIT_DEP' from packages/main"
remove_dep

echo
echo "==> 2a. pnpm install on (canonical + edit)"
reset_lock; $PM install --lockfile-only >/dev/null 2>&1
INSTALL=$(count); cp pnpm-lock.yaml /tmp/repro-install.yaml
echo "    install  supports-color suffix positions: $INSTALL"

echo
echo "==> 2b. pnpm dedupe on (canonical + edit) -- the correct minimal form"
reset_lock; $PM dedupe >/dev/null 2>&1
DEDUPE=$(count); cp pnpm-lock.yaml /tmp/repro-dedupe.yaml
echo "    dedupe   supports-color suffix positions: $DEDUPE"

# restore working tree
restore_main; reset_lock

echo
echo "==> 3. RESULT"
if [ "$INSTALL" != "$DEDUPE" ]; then
  echo "    >>> BUG REPRODUCED: install ($INSTALL) != dedupe ($DEDUPE)"
  echo "    >>> Packages that 'pnpm install' spuriously suffixed (absent from dedupe):"
  diff <(grep "$TOK" /tmp/repro-dedupe.yaml | sort -u) \
       <(grep "$TOK" /tmp/repro-install.yaml | sort -u) | grep '^>' | sed 's/^>/      /'
else
  echo "    install == dedupe == $INSTALL (no divergence on this toolchain)"
fi

exit 0

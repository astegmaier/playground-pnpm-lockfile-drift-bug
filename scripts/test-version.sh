#!/usr/bin/env bash
# Test the install-vs-dedupe drift repro against a specific pnpm version.
# Usage: ./scripts/test-version.sh <version>
set -uo pipefail
cd "$(dirname "$0")/.."
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
VER="$1"
PKG='a/package.json'
ROOT='package.json'
TOK='supports-color@5.5.0)'
count() { grep -c "$TOK" pnpm-lock.yaml 2>/dev/null | head -1; }

# back up working tree
BAK="$(mktemp -d)"
cp "$PKG" "$BAK/pkg.json"; cp pnpm-lock.yaml "$BAK/lock.yaml"; cp "$ROOT" "$BAK/root.json"
restore() { cp "$BAK/pkg.json" "$PKG"; cp "$BAK/lock.yaml" pnpm-lock.yaml; cp "$BAK/root.json" "$ROOT"
            find . -name node_modules -type d -not -path './.git/*' -exec rm -rf {} + 2>/dev/null; rm -rf "$BAK"; }
trap restore EXIT

# pin the version via packageManager (corepack)
node -e "const f='$ROOT',j=require('./'+f);j.packageManager='pnpm@$VER';require('fs').writeFileSync(f,JSON.stringify(j,null,2)+'\n')"

ACTUAL=$(corepack pnpm --version 2>/dev/null)
LFV=$(head -1 pnpm-lock.yaml | tr -d "'\"")

# 1. remove unrelated dep
node -e "const f='$PKG',j=require('./'+f);delete j.dependencies['tiny-invariant'];require('fs').writeFileSync(f,JSON.stringify(j,null,2)+'\n')"

corepack pnpm install >/dev/null 2>&1
INSTALL=$(count)
corepack pnpm dedupe >/dev/null 2>&1
DEDUPE=$(count)

VERDICT="?"
if [ "$INSTALL" = "5" ] && [ "$DEDUPE" = "3" ]; then VERDICT="REPRODUCED"; 
elif [ "$INSTALL" = "$DEDUPE" ]; then VERDICT="not-reproduced(install==dedupe=$INSTALL)"; 
else VERDICT="other(install=$INSTALL,dedupe=$DEDUPE)"; fi

echo "requested=$VER actual=$ACTUAL install=$INSTALL dedupe=$DEDUPE verdict=$VERDICT"

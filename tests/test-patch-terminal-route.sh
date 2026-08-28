#!/usr/bin/env sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
node_bin=${NODE:-}
[ -n "$node_bin" ] || node_bin=$(command -v node 2>/dev/null || true)
[ -n "$node_bin" ] || node_bin=$(command -v nodejs 2>/dev/null || true)
[ -n "$node_bin" ] || [ ! -x /app/extra/app/resources/cua_node/bin/node ] \
    || node_bin=/app/extra/app/resources/cua_node/bin/node
[ -n "$node_bin" ] || { echo "node is required for patch-terminal-route tests" >&2; exit 1; }
"$node_bin" "$repo/tests/test-patch-terminal-route.js"

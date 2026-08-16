#!/usr/bin/env bash
# Fetch the upstream .deb into .cache/ (gitignored) and print its path.
# ~400 MB and three scripts want it, so -z lets a conditional GET decide
# whether the rolling URL has actually moved.
#
# Usage: scripts/fetch-deb.sh [amd64|arm64]
set -euo pipefail

ARCH=${1:-amd64}
URL="https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_${ARCH}.deb"
OUT=".cache/chatgpt_${ARCH}.deb"

mkdir -p .cache
echo ">> fetching $ARCH (cached in $OUT)" >&2

# Never write over a valid cache entry. A ~400 MB transfer that dies partway
# would otherwise leave OUT truncated but freshly stamped, so the next
# conditional request treats the partial file as the cache and every consumer
# reads short bytes: make hashes would pin a sha256 nobody can reproduce.
tmp="$OUT.part"
args=(-fsSL --retry 3 -o "$tmp" -w '%{http_code}')
[ -f "$OUT" ] && args+=(-z "$OUT")

code=$(curl "${args[@]}" "$URL") \
    || { rm -f "$tmp"; echo "fetch-deb: download failed for $URL" >&2; exit 1; }
case "$code" in
    200) mv -f "$tmp" "$OUT" ;;
    304) rm -f "$tmp" ;;   # unchanged upstream, keep what we have
    *)   rm -f "$tmp"; echo "fetch-deb: unexpected HTTP $code for $URL" >&2; exit 1 ;;
esac

echo "$OUT"

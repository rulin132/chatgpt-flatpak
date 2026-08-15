#!/usr/bin/env bash
# Fetch the upstream .deb into .cache/ and print its path.
#
# The payload is ~400 MB and three maintainer scripts want it, so cache it and
# let curl's conditional GET decide whether the rolling URL has moved.
# .cache/ is gitignored; nothing in it is ever committed.
#
# Usage: scripts/fetch-deb.sh [amd64|arm64]
set -euo pipefail

ARCH=${1:-amd64}
URL="https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_${ARCH}.deb"
OUT=".cache/chatgpt_${ARCH}.deb"

mkdir -p .cache
echo ">> fetching $ARCH (cached in $OUT)" >&2
curl -fsSL --retry 3 -z "$OUT" -o "$OUT" "$URL" >&2

echo "$OUT"

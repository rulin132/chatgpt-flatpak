#!/usr/bin/env bash
# Dump the upstream .deb layout. Run this whenever a build starts failing in
# apply_extra — it tells you what actually changed.
#
# Usage: scripts/inspect-deb.sh [amd64|arm64]
set -euo pipefail

ARCH=${1:-amd64}
URL="https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_${ARCH}.deb"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

curl -fsSL -o "$WORK/pkg.deb" "$URL"

echo "=== control ==================================================="
dpkg-deb -I "$WORK/pkg.deb" 2>/dev/null || ar p "$WORK/pkg.deb" control.tar.gz | tar xzO ./control

echo
echo "=== top-level payload dirs ===================================="
dpkg-deb -c "$WORK/pkg.deb" | awk '{print $6}' | cut -d/ -f2-3 | sort -u | head -40

echo
echo "=== app.asar / main binary candidates ========================="
dpkg-deb -c "$WORK/pkg.deb" | grep -E 'app\.asar|chrome-sandbox|/chatgpt$|\.desktop$|icons/.*\.png$' || true

echo
echo "=== anything that smells like a self-updater =================="
dpkg-deb -c "$WORK/pkg.deb" | grep -Ei 'update|appimage|squirrel' || echo "(none obvious)"

echo
echo "=== maintainer scripts (these add OpenAI's apt repo) =========="
dpkg-deb --ctrl-tarfile "$WORK/pkg.deb" | tar t 2>/dev/null || true

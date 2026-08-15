#!/usr/bin/env bash
# Dump the upstream .deb layout. Run this whenever a build starts failing in
# apply_extra. It tells you what actually changed.
#
# Usage: scripts/inspect-deb.sh [amd64|arm64]
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/deb-lib.sh
. scripts/deb-lib.sh

DEB=$(scripts/fetch-deb.sh "${1:-amd64}")
LIST=$(deb_list "$DEB")

echo "=== ar members ================================================"
ar t "$DEB"

echo
echo "=== control ==================================================="
deb_control "$DEB"

echo
echo "=== top-level payload dirs ===================================="
awk '{print $NF}' <<<"$LIST" | cut -d/ -f2-3 | sort -u | head -40

echo
echo "=== app.asar / main binary candidates ========================="
grep -E 'app\.asar|chrome[-_]sandbox|\.desktop$|pixmaps/|icons/.*\.png$' <<<"$LIST" || true

echo
echo "=== executables next to app.asar =============================="
# apply_extra picks the first ELF here that is not a helper. If upstream adds
# another top-level executable, this is where you will see it.
appdir=$(grep -m1 'app\.asar$' <<<"$LIST" | awk '{print $NF}' | xargs dirname | xargs dirname)
grep -E "^-.{8}x.* ${appdir}/[^/]+$" <<<"$LIST" || echo "(none, apply_extra will fail closed)"

echo
echo "=== anything that smells like a self-updater =================="
awk '{print $NF}' <<<"$LIST" | grep -vE '/(node_modules|cua_node)/' \
  | grep -Ei 'update|appimage|squirrel' || echo "(none obvious)"

echo
echo "=== maintainer scripts (these add OpenAI's apt repo) =========="
deb_cat "$DEB" "$(deb_member "$DEB" control.tar)" | tar t

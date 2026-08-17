#!/usr/bin/env bash
# Tests for scripts/refresh-source.sh, which rewrites the file that decides
# what bytes every user installs. It runs unattended with auto-merge armed, so
# a silent mis-rewrite ships to real machines with no human reading the diff.
#
# The upstream APT index is stubbed with file:// URLs via DEB_REPO_BASE.
#
# Usage: tests/test-refresh-source.sh
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$REPO/scripts/refresh-source.sh
pass=0 fail=0

ok()   { pass=$((pass + 1)); echo "  ok   $1"; }
bad()  { fail=$((fail + 1)); echo "  FAIL $1"; }
check() {  # name haystack needle
    if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1"; echo "       expected: $3"; fi
}

# Build a workspace: stub APT repo, a manifest still on the old rolling URLs,
# and a metainfo scaffold. $1/$2 = versions for the amd64/arm64 indexes.
make_work() {
    local work amd64_ver=$1 arm64_ver=$2
    work=$(mktemp -d)
    mkdir -p "$work/build-aux" \
             "$work/repo/dists/stable/main/binary-amd64" \
             "$work/repo/dists/stable/main/binary-arm64"

    # Two stanzas for amd64: an older version first, plus an unrelated package.
    # The parser has to filter by Package and pick the newest by version sort,
    # not by stanza order.
    cat > "$work/repo/dists/stable/main/binary-amd64/Packages" <<EOF
Package: chatgpt
Version: 26.99.9
Architecture: amd64
Filename: pool/main/c/chatgpt/chatgpt_26.99.9_amd64.deb
Size: 111
SHA256: 1111111111111111111111111111111111111111111111111111111111111111

Package: chatgpt-helper
Version: 99.0.0
Architecture: amd64
Filename: pool/main/c/chatgpt-helper/chatgpt-helper_99.0.0_amd64.deb
Size: 222
SHA256: 2222222222222222222222222222222222222222222222222222222222222222

Package: chatgpt
Version: $amd64_ver
Architecture: amd64
Filename: pool/main/c/chatgpt/chatgpt_${amd64_ver}_amd64.deb
Size: 400000001
SHA256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
    cat > "$work/repo/dists/stable/main/binary-arm64/Packages" <<EOF
Package: chatgpt
Version: $arm64_ver
Architecture: arm64
Filename: pool/main/c/chatgpt/chatgpt_${arm64_ver}_arm64.deb
Size: 400000002
SHA256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF

    cat > "$work/test.ChatGPT.yaml" <<'EOF'
modules:
  - name: chatgpt
    sources:
      - type: extra-data
        filename: chatgpt.deb
        only-arches:
          - x86_64
        url: https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_amd64.deb
        sha256: 0000000000000000000000000000000000000000000000000000000000000000
        size: 1
        x-checker-data:
          type: rotating-url
          url: https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_amd64.deb
          is-main-source: true
      - type: extra-data
        filename: chatgpt.deb
        only-arches:
          - aarch64
        url: https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_arm64.deb
        sha256: 0000000000000000000000000000000000000000000000000000000000000001
        size: 2
EOF

    cat > "$work/build-aux/test.metainfo.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>test</id>
  <releases>
    <release version="0.0.0" date="2026-08-14"/>
  </releases>
</component>
EOF
    echo "$work"
}

echo "refresh-source.sh"

# --- happy path: migrate from rolling URLs to versioned pool pins ------------
work=$(make_work 27.100.11111 27.100.11111)
out=$( cd "$work" && DEB_REPO_BASE="file://$work/repo" "$SCRIPT" test.ChatGPT.yaml 2>&1 ) \
    || { bad "happy path exited non-zero"; printf '%s\n' "$out"; }
manifest=$(cat "$work/test.ChatGPT.yaml")

check "x86_64 url is the versioned pool path" "$manifest" \
      "url: file://$work/repo/pool/main/c/chatgpt/chatgpt_27.100.11111_amd64.deb"
check "aarch64 url is the versioned pool path" "$manifest" \
      "url: file://$work/repo/pool/main/c/chatgpt/chatgpt_27.100.11111_arm64.deb"
check "x86_64 sha256 from the index"  "$manifest" "sha256: aaaaaaaa"
check "aarch64 sha256 from the index" "$manifest" "sha256: bbbbbbbb"
check "x86_64 size from the index"    "$manifest" "size: 400000001"
check "picked 27.100.11111 over 26.99.9 by version, not stanza order" "$out" \
      ">> upstream version: 27.100.11111"
check "x-checker-data url left untouched" "$manifest" \
      "url: https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_amd64.deb"
check "metainfo release updated" "$(cat "$work/build-aux/test.metainfo.xml")" \
      '<release version="27.100.11111"'

# The three fields must stay adjacent lines. A regex that eats the preceding
# newline into its indent group reproduces url/sha256/size separated by blank
# lines, which line-by-line greps cannot see and idempotence cannot catch,
# because the second run regenerates the same layout.
for a in amd64 arm64; do
    block=$(grep -A2 "chatgpt_27.100.11111_$a.deb" "$work/test.ChatGPT.yaml")
    if sed -n 2p <<<"$block" | grep -q '^ *sha256:' \
        && sed -n 3p <<<"$block" | grep -q '^ *size:'; then
        ok "$a url/sha256/size are adjacent lines"
    else
        bad "$a url/sha256/size are adjacent lines"; printf '%s\n' "$block"
    fi
done

# --- idempotence: a second run against the same index changes nothing --------
before=$(cat "$work/test.ChatGPT.yaml")
( cd "$work" && DEB_REPO_BASE="file://$work/repo" "$SCRIPT" test.ChatGPT.yaml ) >/dev/null 2>&1 \
    || bad "second run exited non-zero"
if [ "$before" = "$(cat "$work/test.ChatGPT.yaml")" ]; then
    ok "re-run is a no-op on the manifest"
else
    bad "re-run is a no-op on the manifest"
fi
rm -rf "$work"

# --- disagreeing indexes: fail closed, write nothing -------------------------
work=$(make_work 27.100.11111 27.100.22222)
before=$(cat "$work/test.ChatGPT.yaml")
if out=$( cd "$work" && DEB_REPO_BASE="file://$work/repo" "$SCRIPT" test.ChatGPT.yaml 2>&1 ); then
    bad "disagreeing indexes must exit non-zero"
else
    ok "disagreeing indexes exit non-zero"
fi
check "and say which versions disagreed" "$out" "x86_64=27.100.11111 aarch64=27.100.22222"
if [ "$before" = "$(cat "$work/test.ChatGPT.yaml")" ]; then
    ok "manifest untouched on disagreement"
else
    bad "manifest untouched on disagreement"
fi
check "metainfo untouched on disagreement" \
      "$(cat "$work/build-aux/test.metainfo.xml")" 'version="0.0.0"'
rm -rf "$work"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

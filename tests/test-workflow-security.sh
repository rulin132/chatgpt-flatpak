#!/usr/bin/env bash
# Security invariants for executable workflow dependencies and release secrets.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
pass=0 fail=0

ok()  { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; }

echo "workflow security"

# A mutable major tag can be repointed after review. All external actions must
# resolve to a full commit SHA; local actions remain allowed.
while IFS=: read -r file line text; do
    ref=$(sed -E 's/.*uses:[[:space:]]*([^[:space:]#]+).*/\1/' <<<"$text")
    if [[ "$ref" == ./* ]]; then
        continue
    fi
    if [[ "$ref" =~ ^[^@]+@[0-9a-f]{40}$ ]]; then
        ok "$file:$line pins $ref"
    else
        bad "$file:$line uses mutable action $ref"
    fi
done < <(grep -HnE 'uses:[[:space:]]*[^[:space:]#]+' "$REPO"/.github/workflows/*.yml)

# The build container executes while the signing key is present, so its tag
# must resolve to one immutable manifest digest.
while IFS=: read -r file line text; do
    ref=$(sed -E 's/.*image:[[:space:]]*([^[:space:]#]+).*/\1/' <<<"$text")
    if [[ "$ref" =~ ^[^@]+@sha256:[0-9a-f]{64}$ ]]; then
        ok "$file:$line pins its container digest"
    else
        bad "$file:$line uses mutable container $ref"
    fi
done < <(grep -HnE 'image:[[:space:]]*[^[:space:]#]+' "$REPO"/.github/workflows/*.yml)

# No third-party upload or release action should run while the imported private
# key remains on disk.
release=$REPO/.github/workflows/release.yml
# shellcheck disable=SC2016
cleanup_line=$(grep -nF 'rm -rf -- "$GNUPGHOME"' "$release" | cut -d: -f1)
first_upload_line=$(grep -n 'uses: actions/upload-pages-artifact@' "$release" | cut -d: -f1)
if [ -n "$cleanup_line" ] && [ -n "$first_upload_line" ] \
    && [ "$cleanup_line" -lt "$first_upload_line" ]; then
    ok "signing key is removed before third-party upload actions"
else
    bad "signing key must be removed before third-party upload actions"
fi

if grep -A2 -F -- '- name: remove signing key' "$release" | grep -qF 'if: always()'; then
    ok "signing key cleanup runs on failure"
else
    bad "signing key cleanup must run on failure"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

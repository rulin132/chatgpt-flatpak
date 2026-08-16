#!/usr/bin/env bash
# Tests for scripts/merge-repos.sh. A published repo missing an architecture is
# invisible until an aarch64 user tries to install, so this asserts both refs
# survive the merge and that an empty source is refused rather than skipped.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$REPO/scripts/merge-repos.sh
pass=0 fail=0

check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"
    else fail=$((fail + 1)); echo "  FAIL $1: expected '$3', got '$2'"; fi
}

work=$(mktemp -d)
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT

# Two source repos, each with one arch ref, standing in for the two build jobs.
for arch in x86_64 aarch64; do
    ostree --repo="$work/src-$arch" init --mode=archive-z2 >/dev/null
    mkdir -p "$work/tree-$arch"
    echo "$arch" > "$work/tree-$arch/marker"
    ostree --repo="$work/src-$arch" commit \
        --branch="app/io.github.rulin132.ChatGPT/$arch/master" \
        --subject=test "$work/tree-$arch" >/dev/null
done

"$SCRIPT" "$work/dest" "$work/src-x86_64" "$work/src-aarch64" >/dev/null
refs=$(ostree --repo="$work/dest" refs | sort | tr '\n' ' ')
check "both arch refs present" "$refs" \
  "app/io.github.rulin132.ChatGPT/aarch64/master app/io.github.rulin132.ChatGPT/x86_64/master "

# A build job that produced nothing must fail the merge, not be silently dropped.
ostree --repo="$work/empty" init --mode=archive-z2 >/dev/null
if "$SCRIPT" "$work/dest2" "$work/src-x86_64" "$work/empty" >/dev/null 2>&1; then
    fail=$((fail + 1)); echo "  FAIL empty source must fail closed"
else
    pass=$((pass + 1)); echo "  ok   empty source fails closed"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

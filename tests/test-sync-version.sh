#!/usr/bin/env bash
# Tests for scripts/sync-version.sh, the one script that rewrites a file which
# nothing else validates: flatpak-external-data-checker cannot bump the
# AppStream version (the upstream URL is a rolling alias that never changes), so
# if this silently does the wrong thing the published version just goes stale.
#
# Usage: tests/test-sync-version.sh
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$REPO/scripts/sync-version.sh
pass=0 fail=0

# Run sync-version.sh against a throwaway metainfo file and echo the result.
# $1 = the <releases> body, $2.. = args to sync-version.sh
run_case() {
    local releases=$1; shift
    local work; work=$(mktemp -d)
    mkdir -p "$work/build-aux"
    cat > "$work/build-aux/test.metainfo.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>test</id>
  <releases>
$releases  </releases>
</component>
EOF
    ( cd "$work" && "$SCRIPT" "$@" ) >"$work/stdout" 2>&1 || echo "EXIT_NONZERO" >>"$work/stdout"
    cat "$work/build-aux/test.metainfo.xml" "$work/stdout"
    rm -rf "$work"
}

check() {
    local name=$1 haystack=$2 needle=$3
    if grep -qF -- "$needle" <<<"$haystack"; then
        pass=$((pass + 1)); echo "  ok   $name"
    else
        fail=$((fail + 1)); echo "  FAIL $name"; echo "       expected to find: $needle"
        printf '%s\n' "$haystack"
    fi
}
check_absent() {
    local name=$1 haystack=$2 needle=$3
    if grep -qF -- "$needle" <<<"$haystack"; then
        fail=$((fail + 1)); echo "  FAIL $name"; echo "       expected NOT to find: $needle"
    else
        pass=$((pass + 1)); echo "  ok   $name"
    fi
}

echo "sync-version.sh"

# A fresh scaffold carries the 0.0.0 placeholder; the real version must replace
# it rather than stack on top of it.
out=$(run_case '    <release version="0.0.0" date="2026-08-14"/>
' 26.810.50856 2026-08-15)
check        "inserts the new version"        "$out" '<release version="26.810.50856" date="2026-08-15"/>'
check_absent "drops the 0.0.0 placeholder"    "$out" 'version="0.0.0"'

# Re-running after a no-op upstream check must not duplicate the entry.
out=$(run_case '    <release version="26.810.50856" date="2026-08-15"/>
' 26.810.50856 2026-08-15)
check        "existing version is a no-op"    "$out" 'already present'
check        "and is not duplicated"          "$out" "$(printf '%s' '<release version="26.810.50856"')"
if [ "$(grep -c 'version="26.810.50856"' <<<"$out")" -eq 1 ]; then
    pass=$((pass + 1)); echo "  ok   exactly one entry after re-run"
else
    fail=$((fail + 1)); echo "  FAIL exactly one entry after re-run"
fi

# History is capped at five so the metainfo does not grow without bound.
out=$(run_case '    <release version="5.0.0" date="2026-08-05"/>
    <release version="4.0.0" date="2026-08-04"/>
    <release version="3.0.0" date="2026-08-03"/>
    <release version="2.0.0" date="2026-08-02"/>
    <release version="1.0.0" date="2026-08-01"/>
' 6.0.0 2026-08-06)
check        "newest entry is first"          "$out" '<release version="6.0.0" date="2026-08-06"/>'
check        "keeps the four next-newest"     "$out" '<release version="2.0.0"'
check_absent "evicts the sixth"               "$out" '<release version="1.0.0"'

# Upstream can re-publish a version we already list (a rollback). The entry has
# to move to the front: ci-smoke.sh reads the first one, so a no-op here leaves
# the head entry wrong and CI red on every arch, every night, with no recovery.
out=$(run_case '    <release version="5.0.0" date="2026-08-05"/>
    <release version="4.0.0" date="2026-08-04"/>
    <release version="3.0.0" date="2026-08-03"/>
' 4.0.0 2026-08-07)
check "rollback moves the entry to the front" "$(grep -m1 '<release ' <<<"$out")" \
      '<release version="4.0.0" date="2026-08-07"/>'
if [ "$(grep -c 'version="4.0.0"' <<<"$out")" -eq 1 ]; then
    pass=$((pass + 1)); echo "  ok   rollback leaves exactly one entry"
else
    fail=$((fail + 1)); echo "  FAIL rollback leaves exactly one entry"
    printf '%s\n' "$out"
fi

# A metainfo with no <releases> block must abort, not write a broken file.
work=$(mktemp -d); mkdir -p "$work/build-aux"
printf '<component><id>test</id></component>\n' > "$work/build-aux/test.metainfo.xml"
if ( cd "$work" && "$SCRIPT" 1.2.3 ) >/dev/null 2>&1; then
    fail=$((fail + 1)); echo "  FAIL missing <releases> must fail closed"
else
    pass=$((pass + 1)); echo "  ok   missing <releases> fails closed"
fi
rm -rf "$work"

# Versions originate in upstream APT metadata and later become Actions
# outputs. Reject shell metacharacters and XML delimiters before writing them.
# shellcheck disable=SC2016 -- literal substitutions are the test inputs
for bad_version in '1.2.3$(touch PWNED)' '1.2.3`id`' '1.2.3"/>' '1.2.3 with-space'; do
    out=$(run_case '    <release version="0.0.0" date="2026-08-14"/>
' "$bad_version" 2026-08-15)
    check "rejects unsafe version: $bad_version" "$out" 'EXIT_NONZERO'
    check_absent "does not write unsafe version: $bad_version" "$out" "$bad_version"
done

# Debian versions legitimately use epochs and distro revision punctuation.
out=$(run_case '    <release version="0.0.0" date="2026-08-14"/>
' '1:2.3.4-5+dist~1' 2026-08-15)
check "accepts Debian version punctuation" "$out" \
      '<release version="1:2.3.4-5+dist~1" date="2026-08-15"/>'

# GitHub expressions are substituted before a run block reaches the shell.
# External values must enter through env and be expanded as quoted variables.
run_blocks=$(awk '
    /^[[:space:]]+run:[[:space:]]*(\|[+-]?)?[[:space:]]*$/ {
        in_run = 1; indent = match($0, /[^ ]/) - 1; next
    }
    in_run {
        current = match($0, /[^ ]/) - 1
        if (current >= 0 && current <= indent) in_run = 0
        else print
    }
' "$REPO/.github/workflows/release.yml")
# shellcheck disable=SC2016 -- literal Actions expressions are the test inputs
for expression in \
    '${{ github.ref_name }}' '${{ steps.ver.outputs.v }}' \
    '${{ secrets.GITHUB_TOKEN }}' '${{ github.actor }}' \
    '${{ needs.publish.outputs.version }}' '${{ github.repository_owner }}'; do
    check_absent "shell blocks do not interpolate $expression" "$run_blocks" "$expression"
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

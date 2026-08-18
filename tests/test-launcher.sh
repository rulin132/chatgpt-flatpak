#!/usr/bin/env bash
# Tests for build-aux/launcher.sh. The NVIDIA GL-extension mismatch is invisible
# until rendering silently degrades (opaque pet overlay), so this asserts the
# launcher warns on the mismatch, stays quiet on healthy stacks, and never
# blocks the launch either way. The launcher inspects a hardcoded (empty) PREFIX
# that points at the sandbox root; tests run a copy with that one line rewritten
# to a fake root. zypak-wrapper is stubbed on PATH. The shipped launcher must
# NOT honor an env var for this: an ambient override of a sourced path would be
# code execution before zypak sandboxes anything (see the env-ignored test).
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
LAUNCHER=$REPO/build-aux/launcher.sh
pass=0 fail=0

check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"
    else fail=$((fail + 1)); echo "  FAIL $1: expected '$3', got '$2'"; fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/stub"
printf '#!/bin/sh\necho "ZYPAK_EXEC $*"\n' > "$work/stub/zypak-wrapper"
chmod +x "$work/stub/zypak-wrapper"
export PATH="$work/stub:$PATH"

mkroot() {  # mkroot <name>; prints the root path
    local root=$work/$1
    mkdir -p "$root/app/extra" "$root/dev" "$root/usr/lib/x86_64-linux-gnu/GL"
    echo "APP_BIN=/fake/ChatGPT" > "$root/app/extra/app.env"
    echo "$root"
}

# Copy the launcher with PREFIX rewritten to a fake root, then run it. This is
# the only substitution point; the shipped script keeps PREFIX empty.
run_launcher() {  # run_launcher <root>; stdout to $out, stderr to $err, rc set
    err=$work/err; out=$work/out; copy=$work/launcher-copy.sh
    sed "s|^PREFIX=\$|PREFIX=$1|" "$LAUNCHER" > "$copy"
    XDG_CACHE_HOME=$work/cache sh "$copy" >"$out" 2>"$err" && rc=0 || rc=$?
}

# NVIDIA node without a mounted GL/nvidia-* dir is the driver/extension
# mismatch: must warn on stderr but still launch.
root=$(mkroot mismatch)
touch "$root/dev/nvidiactl"
run_launcher "$root"
check "mismatch: warns on stderr" \
    "$(grep -c 'flatpak update' "$err")" "1"
check "mismatch: still execs the app" \
    "$(grep -c '^ZYPAK_EXEC /fake/ChatGPT' "$out")" "1"
check "mismatch: exit 0" "$rc" "0"

# Matching extension mounted: no warning.
root=$(mkroot matched)
touch "$root/dev/nvidiactl"
mkdir -p "$root/usr/lib/x86_64-linux-gnu/GL/nvidia-610-43-03"
run_launcher "$root"
check "matched: no warning" "$(wc -c < "$err")" "0"
check "matched: execs the app" \
    "$(grep -c '^ZYPAK_EXEC /fake/ChatGPT' "$out")" "1"

# No NVIDIA device at all (AMD/Intel, Mesa in the runtime): no warning.
root=$(mkroot nonvidia)
run_launcher "$root"
check "no nvidia: no warning" "$(wc -c < "$err")" "0"
check "no nvidia: execs the app" \
    "$(grep -c '^ZYPAK_EXEC /fake/ChatGPT' "$out")" "1"

# Missing app.env still fails closed with the reinstall hint.
root=$work/noenv
mkdir -p "$root"
run_launcher "$root"
check "missing app.env: exit 1" "$rc" "1"
check "missing app.env: reinstall hint" \
    "$(grep -c 'reinstall' "$err")" "1"

# Security regression: the SHIPPED launcher (PREFIX empty, not substituted) must
# ignore any ambient env var and source only the real /app path. A malicious
# app.env planted in a fake root pointed at by a plausible env-var name must not
# be sourced. We run the unmodified launcher; it looks at /app/extra/app.env
# (absent here) and fails closed before any injected code could run.
evil=$(mkroot evil)
printf 'APP_BIN=/x\ntouch %s/PWNED\n' "$work" > "$evil/app/extra/app.env"
CHATGPT_LAUNCHER_ROOT=$evil PREFIX=$evil ROOT=$evil \
    XDG_CACHE_HOME=$work/cache sh "$LAUNCHER" >/dev/null 2>&1 || true
check "shipped launcher ignores ambient env (no code injection)" \
    "$( [ -e "$work/PWNED" ] && echo INJECTED || echo safe )" "safe"

echo "launcher: $pass ok, $fail failed"
[ "$fail" -eq 0 ]

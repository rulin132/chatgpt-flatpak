#!/usr/bin/env bash
# Verify that the Flatpak compatibility wrapper selects Codex's no-inner-
# sandbox mode before all caller arguments and resolves codex.real beside
# itself, independent of the current working directory.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
WRAPPER=$REPO/build-aux/codex-flatpak-wrapper

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/resources" "$work/elsewhere"
cp "$WRAPPER" "$work/resources/codex"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "$@"' > "$work/resources/codex.real"
chmod +x "$work/resources/codex" "$work/resources/codex.real"

actual=$(cd "$work/elsewhere" && "$work/resources/codex" app-server --flag 'two words')
expected=$(printf '%s\n' -c 'sandbox_mode="danger-full-access"' app-server --flag 'two words')

if [ "$actual" != "$expected" ]; then
    echo "FAIL: wrapper changed option ordering or caller arguments" >&2
    diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") || true
    exit 1
fi

echo "codex-flatpak-wrapper: 1 ok, 0 failed"

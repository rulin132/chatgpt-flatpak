#!/bin/sh
# Launcher. Runs zypak so Chromium's renderer/GPU processes stay in nested
# flatpak sub-sandboxes. Never add --no-sandbox here: it would let compromised
# web content inherit every permission this flatpak holds.
set -eu

[ -f /app/extra/app.env ] || { echo "chatgpt: app.env missing, reinstall the flatpak" >&2; exit 1; }
# shellcheck source=/dev/null  # written by apply_extra at install time
. /app/extra/app.env

export TMPDIR="${XDG_CACHE_HOME:-$HOME/.cache}/tmp"
mkdir -p "$TMPDIR"

# --enable-wayland-ime is what fixes IME input on Fedora/GNOME Wayland.
set -- --ozone-platform-hint=auto --enable-wayland-ime "$@"

# CHATGPT_DISABLE_GPU=1 renders in software (see docs/SECURITY.md).
# Deliberately not --disable-gpu: that leaves no rasteriser and opens no window
# at all. Measured on 26.810.52044, --disable-gpu gives 0 windows, this gives 2.
[ "${CHATGPT_DISABLE_GPU:-0}" = "1" ] && set -- --use-angle=swiftshader "$@"

exec zypak-wrapper "$APP_BIN" "$@"

#!/bin/sh
# Launcher. Runs zypak so Chromium's renderer/GPU processes stay in nested
# flatpak sub-sandboxes. Never add --no-sandbox here: it would let compromised
# web content inherit every permission this flatpak holds.
set -eu

[ -f /app/extra/app.env ] || { echo "chatgpt: app.env missing — reinstall the flatpak" >&2; exit 1; }
. /app/extra/app.env

# Electron writes scratch data next to $TMPDIR; keep it inside the per-app dir.
export TMPDIR="${XDG_CACHE_HOME:-$HOME/.cache}/tmp"
mkdir -p "$TMPDIR"

# Ozone picks Wayland when available and falls back to X11 automatically.
# --enable-wayland-ime is what fixes IME input on Fedora/GNOME Wayland.
set -- --ozone-platform-hint=auto --enable-wayland-ime "$@"

# Opt-in escape hatches, off by default (see docs/SECURITY.md):
#   CHATGPT_DISABLE_GPU=1   drop hardware acceleration if you hit a blank window
[ "${CHATGPT_DISABLE_GPU:-0}" = "1" ] && set -- --disable-gpu "$@"

exec zypak-wrapper "$APP_BIN" "$@"

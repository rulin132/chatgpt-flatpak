#!/bin/sh
# Launcher. Runs zypak so Chromium's renderer/GPU processes stay in nested
# flatpak sub-sandboxes. Never add --no-sandbox here: it would let compromised
# web content inherit every permission this flatpak holds.
set -eu

[ -f /app/extra/app.env ] || { echo "chatgpt: app.env missing, reinstall the flatpak" >&2; exit 1; }
# shellcheck source=/dev/null  # written by apply_extra at install time
. /app/extra/app.env

# Electron writes scratch data next to $TMPDIR; keep it inside the per-app dir.
export TMPDIR="${XDG_CACHE_HOME:-$HOME/.cache}/tmp"
mkdir -p "$TMPDIR"

# Ozone picks Wayland when available and falls back to X11 automatically.
# --enable-wayland-ime is what fixes IME input on Fedora/GNOME Wayland.
set -- --ozone-platform-hint=auto --enable-wayland-ime "$@"

# Opt-in escape hatches, off by default (see docs/SECURITY.md):
#   CHATGPT_DISABLE_GPU=1   render in software if you hit a blank window
#
# Not --disable-gpu. That leaves Chromium with no rasteriser at all here, so it
# aborts with "GPU access not allowed. Reason: GPU access is disabled through
# commandline switch --disable-gpu and --disable-software-rasterizer" and no
# window ever appears, which is worse than the blank window it was meant to fix.
# Routing ANGLE at the bundled SwiftShader drops the driver but keeps rendering.
# Measured on 26.810.52044: --disable-gpu gives 0 windows, this gives 2.
[ "${CHATGPT_DISABLE_GPU:-0}" = "1" ] && set -- --use-angle=swiftshader "$@"

exec zypak-wrapper "$APP_BIN" "$@"

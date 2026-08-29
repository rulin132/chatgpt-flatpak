#!/bin/sh
# Launcher. Runs zypak so Chromium's renderer/GPU processes stay in nested
# flatpak sub-sandboxes. Never add --no-sandbox here: it would let compromised
# web content inherit every permission this flatpak holds.
set -eu

# Filesystem prefix the launcher inspects. Empty in the shipped launcher;
# tests/test-launcher.sh runs a copy with this one line rewritten to a fake
# root. Deliberately NOT sourced from an env var: an ambient override of a
# path that gets `.`-sourced below would be arbitrary code execution before
# zypak sandboxes anything.
PREFIX=

[ -f "$PREFIX/app/extra/app.env" ] || { echo "chatgpt: app.env missing, reinstall the flatpak" >&2; exit 1; }
# shellcheck source=/dev/null  # written by apply_extra at install time
. "$PREFIX/app/extra/app.env"

# Flatpak mounts GL/nvidia-* only when the extension matches the host driver,
# so an NVIDIA device node with no such dir means the host driver updated ahead
# of the extension. Chromium then silently falls back to software rendering and
# transparent overlays (the pet) go opaque; see README known issues.
# ponytail: also fires on NVIDIA+iGPU hybrids that render fine on Mesa;
# stderr-only, so acceptable until someone needs vendor detection.
if [ -e "$PREFIX/dev/nvidiactl" ]; then
    gl_ok=0
    for d in "$PREFIX"/usr/lib/*/GL/nvidia-*; do
        [ -d "$d" ] && { gl_ok=1; break; }
    done
    [ "$gl_ok" = 1 ] || echo "chatgpt: NVIDIA GPU present but no matching GL \
extension is mounted; rendering falls back to software and window transparency \
breaks. Run 'flatpak update', then restart the app." >&2
fi

export TMPDIR="${XDG_CACHE_HOME:-$HOME/.cache}/tmp"
mkdir -p "$TMPDIR"

# The Freedesktop runtime intentionally does not ship Git. ChatGPT downloads a
# confined primary runtime that includes Git, but its main process does not add
# that fallback directory to PATH. The integrated terminal asks the Git manager
# for worktree environment variables before spawning the PTY, so without this
# it fails with "Git is unavailable" and the empty bottom panel collapses.
# Only use the app-managed runtime when it is present; first launch remains
# functional while that runtime is still being installed.
PRIMARY_RUNTIME_FALLBACK_BIN="$PREFIX$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/bin/fallback"
if [ -x "$PRIMARY_RUNTIME_FALLBACK_BIN/git" ]; then
    export PATH="$PRIMARY_RUNTIME_FALLBACK_BIN:$PATH"
fi

# --enable-wayland-ime is what fixes IME input on Fedora/GNOME Wayland.
set -- --ozone-platform-hint=auto --enable-wayland-ime "$@"

# CHATGPT_DISABLE_GPU=1 renders in software (see docs/SECURITY.md).
# Deliberately not --disable-gpu: that leaves no rasteriser and opens no window
# at all. Measured on 26.810.52044, --disable-gpu gives 0 windows, this gives 2.
[ "${CHATGPT_DISABLE_GPU:-0}" = "1" ] && set -- --use-angle=swiftshader "$@"

exec zypak-wrapper "$APP_BIN" "$@"

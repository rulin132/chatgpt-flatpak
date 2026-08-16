#!/usr/bin/env bash
# ci-smoke.sh: post-install assertions for the CI smoke test step.
#
# Assumes the app is already installed under the given app id (the caller
# does remote-add + flatpak install first; that part differs between
# build.yml's throwaway CI repo and release.yml's published one, so it stays
# in the workflow, not here).
#
# No launch assertion: this container runs the job as root, and Chromium's
# zygote host hard-refuses to start its sandbox as root without --no-sandbox
# (see zygote_host_impl_linux.cc), which is forbidden in this repo since it
# would defeat the sandbox the packaging exists to keep. So a real launch
# cannot be asserted here; these payload assertions are what's left, and they
# are still real (apply_extra actually unpacked a real payload, not just a
# zero exit). The launch check is still valid to run locally, where the
# session isn't root:
#   flatpak run --nosocket=session-bus io.github.rulin132.ChatGPT
# Reaching "window ready-to-show" in its output is the signal.
set -euo pipefail

app_id="${1:?usage: ci-smoke.sh <app-id>}"

version=$(flatpak run --command=cat "$app_id" /app/extra/VERSION)
echo "apply_extra reported upstream version: $version"
test -n "$version" && test "$version" != unknown

# shellcheck disable=SC2016  # single-quoted on purpose: expands inside the sandbox, not here
flatpak run --command=sh "$app_id" -c '
  set -eu
  test -f /app/extra/app.env || { echo "no app.env"; exit 1; }
  . /app/extra/app.env
  test -x "$APP_BIN" || { echo "APP_BIN not executable: $APP_BIN"; exit 1; }
  head -c4 "$APP_BIN" | grep -q ELF || { echo "APP_BIN is not an ELF binary"; exit 1; }
  test -f /app/extra/app/resources/app.asar || { echo "no app.asar"; exit 1; }
  echo "payload OK: $APP_BIN"
'

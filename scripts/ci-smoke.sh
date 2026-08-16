#!/usr/bin/env bash
# ci-smoke.sh: post-install assertions for the CI smoke test step.
#
# Assumes the app is already installed under the given app id (the caller
# does remote-add + flatpak install first; that part differs between
# build.yml's throwaway CI repo and release.yml's published one, so it stays
# in the workflow, not here).
#
# Two layers: apply_extra actually unpacked a real payload (not just a zero
# exit), and the payload actually launches (not just that it unpacked).
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

# The payload unpacking is not proof it runs. zypak needs no session
# bus (measured), but Electron needs a display, so give it a virtual
# one. timeout kills a healthy app, so the grep decides, not the exit.
xvfb-run -a --server-args='-screen 0 1280x800x24' \
  timeout 120 flatpak run "$app_id" > /tmp/launch.log 2>&1 || true
grep -q 'window ready-to-show' /tmp/launch.log || {
  echo "app never reached window ready-to-show"
  grep -viE 'statsig' /tmp/launch.log | tail -40
  exit 1
}
echo "launch OK: $(grep -m1 'window ready-to-show' /tmp/launch.log)"

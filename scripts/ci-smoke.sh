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
[ -n "$version" ] || { echo "VERSION is empty"; exit 1; }
[ "$version" != unknown ] || { echo "VERSION is unknown, control file unreadable"; exit 1; }

# The amd64 and arm64 URLs rotate independently, so both arches passing an
# empty-or-unknown check still allows them to be pinned at different upstream
# versions. Compare against the AppStream release each job was built from.
metainfo=$(dirname "$0")/../build-aux/io.github.rulin132.ChatGPT.metainfo.xml
[ -f "$metainfo" ] || { echo "cannot find $metainfo"; exit 1; }
want=$(sed -n 's/.*<release version="\([^"]*\)".*/\1/p' "$metainfo" | head -n1)
[ -n "$want" ] || { echo "no <release version> in $metainfo"; exit 1; }
[ "$version" = "$want" ] || {
  echo "payload is $version but AppStream says $want; the pinned arches disagree"
  exit 1
}
echo "version matches AppStream: $want"

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

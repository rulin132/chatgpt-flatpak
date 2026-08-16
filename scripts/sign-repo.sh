#!/usr/bin/env bash
# GPG-sign every commit in an OSTree repo, then assert none were missed.
#
# The assertion is the point. A repo whose summary is signed but whose commits
# are not passes `flatpak remote-add` and `flatpak remote-ls`, because both read
# only the summary, and fails at `flatpak install` on every user's machine with
# "GPG verification enabled, but no signatures found". That shipped once.
#
# Usage: scripts/sign-repo.sh <repo> <key-id>
set -euo pipefail

REPO=${1:?usage: sign-repo.sh <repo> <key-id>}
KEY=${2:?usage: sign-repo.sh <repo> <key-id>}

signed() {
    ostree --repo="$REPO" show --print-detached-metadata-key=ostree.gpgsigs \
        "$1" >/dev/null 2>&1
}

for ref in $(ostree --repo="$REPO" refs); do
    if signed "$ref"; then
        echo "sign-repo: $ref already signed"
        continue
    fi
    ostree --repo="$REPO" gpg-sign "$ref" "$KEY"
    echo "sign-repo: signed $ref"
done

missing=()
for ref in $(ostree --repo="$REPO" refs); do
    signed "$ref" || missing+=("$ref")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "sign-repo: unsigned after signing: ${missing[*]}" >&2
    exit 1
fi
echo "sign-repo: every ref in $REPO carries a signature"

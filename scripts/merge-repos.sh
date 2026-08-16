#!/usr/bin/env bash
# Merge per-architecture OSTree repos into one publishable repo.
#
# release.yml builds each arch on its own native runner, so the halves arrive as
# separate artifacts. Publishing one of them alone yields a remote that silently
# has no aarch64, which is what shipped before this existed.
#
# Usage: scripts/merge-repos.sh <dest-repo> <src-repo>...
set -euo pipefail

DEST=${1:?usage: merge-repos.sh <dest-repo> <src-repo>...}
shift
[ "$#" -gt 0 ] || { echo "merge-repos: no source repos given" >&2; exit 1; }

ostree --repo="$DEST" init --mode=archive-z2

for src in "$@"; do
    refs=$(ostree --repo="$src" refs | grep '^app/' || true)
    [ -n "$refs" ] || { echo "merge-repos: $src has no app/ ref" >&2; exit 1; }
    # No REFS argument: pull-local then copies every ref in $src, including
    # the .Debug runtime extension. (--mirror is a flag of `ostree pull`,
    # the network fetch command; pull-local has no such option and rejects it.)
    ostree --repo="$DEST" pull-local "$src"
    echo "merge-repos: pulled from $src: $(echo "$refs" | tr '\n' ' ')"
done

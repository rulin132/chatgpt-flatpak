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

want=()
for src in "$@"; do
    # No `|| true` here. `ostree refs` fails outright on a repo whose empty
    # directories were stripped in transit, and swallowing that reported it as
    # "no app/ ref", which points the blame at the build job instead.
    all=$(ostree --repo="$src" refs)
    refs=$(printf '%s\n' "$all" | grep '^app/') || {
        echo "merge-repos: $src has no app/ ref" >&2; exit 1; }
    while IFS= read -r ref; do want+=("$ref"); done <<<"$refs"
    # No REFS argument: pull-local then copies every ref in $src, including
    # the .Debug runtime extension. (--mirror is a flag of `ostree pull`,
    # the network fetch command; pull-local has no such option and rejects it.)
    ostree --repo="$DEST" pull-local "$src"
    echo "merge-repos: pulled from $src: $(echo "$refs" | tr '\n' ' ')"
done

# Every app ref that went in has to come out, which is the per-architecture
# assertion: release.yml only fails when there are no app refs at all, so a
# repo carrying one arch would publish silently. That is the failure this
# script exists to prevent.
got=$(ostree --repo="$DEST" refs)
for ref in "${want[@]}"; do
    grep -qxF -- "$ref" <<<"$got" || {
        echo "merge-repos: $ref is missing from the merged repo" >&2; exit 1; }
done
echo "merge-repos: merged repo carries ${#want[@]} app refs: ${want[*]}"

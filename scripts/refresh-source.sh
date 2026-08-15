#!/usr/bin/env bash
# Download the upstream .deb(s), compute sha256 + size, and write them into the
# manifest. Run once to bootstrap; after that the nightly CI job does it.
#
# Usage: scripts/refresh-source.sh [manifest.yaml]
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/deb-lib.sh
. scripts/deb-lib.sh

manifests=(./*.ChatGPT.yaml)
MANIFEST=${1:-${manifests[0]}}

declare -A ARCHES=([x86_64]=amd64 [aarch64]=arm64)
declare -A DEBS=()

for arch in "${!ARCHES[@]}"; do
  deb=$(scripts/fetch-deb.sh "${ARCHES[$arch]}")
  DEBS[$arch]=$deb
  url="https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_${ARCHES[$arch]}.deb"

  sha=$(sha256sum "$deb" | cut -d' ' -f1)
  size=$(stat -c%s "$deb")
  echo "   sha256=$sha size=$size"

  python3 - "$MANIFEST" "$url" "$sha" "$size" <<'PY'
import re, sys
manifest, url, sha, size = sys.argv[1:5]
text = open(manifest).read()

# Rewrite the sha256/size that follow this exact url line, and nothing else.
pattern = re.compile(
    r'(url:\s*' + re.escape(url) + r'\n)'
    r'(\s*)sha256:\s*\S+\n'
    r'\s*size:\s*\d+\n')

def repl(m):
    return f"{m.group(1)}{m.group(2)}sha256: {sha}\n{m.group(2)}size: {size}\n"

text, n = pattern.subn(repl, text, count=1)
if n != 1:
    sys.exit(f"refresh-source: could not locate source block for {url}")
open(manifest, 'w').write(text)
PY
done

# Version comes from the x86_64 control file; keep metainfo in step.
VER=$(deb_version "${DEBS[x86_64]}")
[ -n "$VER" ] || { echo "refresh-source: no Version: in the control file" >&2; exit 1; }
echo ">> upstream version: $VER"
scripts/sync-version.sh "$VER"

echo ">> done. Review the diff before committing."

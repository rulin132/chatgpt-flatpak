#!/usr/bin/env bash
# Download the upstream .deb(s), compute sha256 + size, and write them into the
# manifest. Run once to bootstrap; after that the nightly CI job does it.
#
# Usage: scripts/refresh-source.sh [manifest.yaml]
set -euo pipefail

MANIFEST=${1:-$(ls ./*.ChatGPT.yaml | head -n1)}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

declare -A URLS=(
  [x86_64]="https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_amd64.deb"
  [aarch64]="https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_arm64.deb"
)

for arch in "${!URLS[@]}"; do
  url=${URLS[$arch]}
  echo ">> fetching $arch"
  curl -fsSL --retry 3 -o "$WORK/$arch.deb" "$url"

  sha=$(sha256sum "$WORK/$arch.deb" | cut -d' ' -f1)
  size=$(stat -c%s "$WORK/$arch.deb")
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
VER=$(dpkg-deb -f "$WORK/x86_64.deb" Version 2>/dev/null \
      || { ar p "$WORK/x86_64.deb" control.tar.gz | tar xzO ./control \
           | sed -n 's/^Version:[[:space:]]*//p'; })
echo ">> upstream version: $VER"
scripts/sync-version.sh "$VER"

echo ">> done. Review the diff before committing."

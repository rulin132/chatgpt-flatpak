#!/usr/bin/env bash
# Pull the real application icons out of the upstream .deb into build-aux/icons.
#
# Icons and AppStream metadata must exist at BUILD time — the payload only
# arrives at install time — so they have to be committed to this repo. Rerun
# this if upstream restyles the icon.
set -euo pipefail

URL="https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_amd64.deb"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
OUT=build-aux/icons
mkdir -p "$OUT"

curl -fsSL -o "$WORK/pkg.deb" "$URL"
( cd "$WORK" && dpkg-deb -x pkg.deb x )

found=0
for s in 16 32 48 64 128 256 512; do
  src=$(find "$WORK/x" -path "*${s}x${s}*" -name '*.png' | head -n1 || true)
  if [[ -n "$src" ]]; then
    cp "$src" "$OUT/$s.png"; found=$((found+1))
    echo "  ${s}x${s} <- ${src#"$WORK/x"}"
  else
    echo "  ${s}x${s} MISSING — generating from the largest available"
  fi
done

if (( found == 0 )); then
  echo "extract-icons: no hicolor PNGs in the deb; check for an SVG or .icns instead" >&2
  find "$WORK/x" \( -name '*.svg' -o -name '*.png' \) | head -20 >&2
  exit 1
fi

# Fill gaps by downscaling the largest icon we did get.
big=$(ls -S "$OUT"/*.png | head -n1)
for s in 16 32 48 64 128 256 512; do
  [[ -f "$OUT/$s.png" ]] || magick "$big" -resize "${s}x${s}" "$OUT/$s.png" 2>/dev/null \
    || convert "$big" -resize "${s}x${s}" "$OUT/$s.png"
done
echo "extract-icons: done — commit build-aux/icons/"

#!/usr/bin/env bash
# Pull the real application icons out of the upstream .deb into build-aux/icons.
#
# Icons and AppStream metadata must exist at BUILD time. The payload only
# arrives at install time, so they have to be committed to this repo. Rerun
# this if upstream restyles the icon.
#
# Upstream currently ships a single 1024x1024 /usr/share/pixmaps/chatgpt.png
# and no hicolor tree, so most sizes are downscaled here. If a future .deb
# gains a proper hicolor set, those are preferred over the downscale.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/deb-lib.sh
. scripts/deb-lib.sh

SIZES="16 32 48 64 128 256 512"
OUT=build-aux/icons
DEB=$(scripts/fetch-deb.sh amd64)
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# ImageMagick 7 ships `magick`, 6 ships `convert`. Both accept the flags below.
# Resolved before anything is deleted: on a host with neither, failing here
# leaves the committed icons alone rather than wiping them.
if command -v magick >/dev/null 2>&1; then IM=magick
elif command -v convert >/dev/null 2>&1; then IM=convert
else echo "extract-icons: needs ImageMagick (magick or convert)" >&2; exit 1
fi

# Clear first. The downscale loop below skips any size that already exists, so
# with every size committed this script was a no-op and an upstream icon change
# would silently keep the old ones.
mkdir -p "$OUT"
rm -f "$OUT"/*.png
deb_cat "$DEB" "$(deb_member "$DEB" data.tar)" | tar x -C "$WORK" ./usr/share

# Prefer a real hicolor icon at each size; fall back to the largest PNG shipped.
for s in $SIZES; do
  src=$(find "$WORK" -path "*${s}x${s}*" -name '*.png' | head -n1)
  [ -n "$src" ] || continue
  cp "$src" "$OUT/$s.png"
  echo "  ${s}x${s} <- ${src#"$WORK"}"
done

big=$(find "$WORK" -name '*.png' -printf '%s %p\n' | sort -rn | head -n1 | cut -d' ' -f2-)
[ -n "$big" ] || {
  echo "extract-icons: no PNG in the .deb, check for an SVG or .icns instead" >&2
  find "$WORK" \( -name '*.svg' -o -name '*.icns' \) | head -20 >&2
  exit 1
}

for s in $SIZES; do
  [ -f "$OUT/$s.png" ] && continue
  # ImageMagick otherwise stamps date:create/date:modify/date:timestamp and tIME
  # into every PNG, which leaks the build time and makes the icons
  # irreproducible. -strip alone does not stop it; the date chunks are added
  # back at write time, so exclude them explicitly.
  "$IM" "$big" -resize "${s}x${s}" -strip -define png:exclude-chunk=date,time "$OUT/$s.png"
  echo "  ${s}x${s} <- downscaled from ${big#"$WORK"}"
done

echo "extract-icons: done, commit build-aux/icons/"

#!/usr/bin/env bash
# Write an upstream version into the metainfo <releases> block.
#
# flatpak-external-data-checker cannot do this for us: it decides "version
# changed" by comparing URLs, and our URL is a rolling alias that never
# changes. Without this step the AppStream version silently goes stale.
#
# Usage: scripts/sync-version.sh <version> [date-YYYY-MM-DD]
set -euo pipefail

VER=${1:?usage: sync-version.sh <version> [date]}
DATE=${2:-$(date -u +%Y-%m-%d)}
xmls=(build-aux/*.metainfo.xml)
XML=${xmls[0]}

python3 - "$XML" "$VER" "$DATE" <<'PY'
import re, sys
path, ver, date = sys.argv[1:4]
text = open(path).read()
new = f'    <release version="{ver}" date="{date}"/>'

if f'version="{ver}"' in text:
    print(f"sync-version: {ver} already present, nothing to do")
    sys.exit(0)

# Keep the five most recent releases.
block = re.search(r'  <releases>\n(.*?)  </releases>', text, re.S)
if not block:
    sys.exit("sync-version: no <releases> block found")
existing = [l for l in block.group(1).splitlines()
            if l.strip() and 'version="0.0.0"' not in l]
entries = "\n".join([new] + existing[:4])
text = text[:block.start(1)] + entries + "\n" + text[block.end(1):]
open(path, 'w').write(text)
print(f"sync-version: added {ver} ({date})")
PY

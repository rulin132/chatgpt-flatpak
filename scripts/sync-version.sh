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

[[ "$VER" =~ ^[0-9][-0-9A-Za-z.+:~]{0,127}$ ]] || {
    echo "sync-version: invalid version" >&2
    exit 1
}
[[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || {
    echo "sync-version: invalid date" >&2
    exit 1
}

python3 - "$XML" "$VER" "$DATE" <<'PY'
import re, sys
path, ver, date = sys.argv[1:4]
text = open(path).read()
new = f'    <release version="{ver}" date="{date}"/>'

block = re.search(r'  <releases>\n(.*?)  </releases>', text, re.S)
if not block:
    sys.exit("sync-version: no <releases> block found")
existing = [l for l in block.group(1).splitlines()
            if l.strip() and 'version="0.0.0"' not in l]

if existing and f'version="{ver}"' in existing[0]:
    print(f"sync-version: {ver} already present, nothing to do")
    sys.exit(0)

# An upstream rollback re-publishes a version still in our history. Drop the
# stale entry so the new one lands first. Bailing out instead would leave the
# head entry wrong, and ci-smoke.sh reads the head entry, so CI would stay red
# on every arch with nothing to heal it.
existing = [l for l in existing if f'version="{ver}"' not in l]

# Keep the five most recent releases.
entries = "\n".join([new] + existing[:4])
text = text[:block.start(1)] + entries + "\n" + text[block.end(1):]
open(path, 'w').write(text)
print(f"sync-version: added {ver} ({date})")
PY

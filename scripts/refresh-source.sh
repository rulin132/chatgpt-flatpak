#!/usr/bin/env bash
# Re-pin the manifest from upstream's APT index: url, sha256 and size for both
# arches come from dists/stable/main/binary-*/Packages.
#
# Usage: scripts/refresh-source.sh [manifest.yaml]
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BASE=${DEB_REPO_BASE:-https://persistent.oaistatic.com/codex-app-prod/linux/deb}

manifests=(./*.ChatGPT.yaml)
MANIFEST=${1:-${manifests[0]}}

# stdin: a Packages index. stdout: "version filename size sha256" for the
# newest chatgpt stanza (an index may list several versions).
parse_index() {
    awk -v RS= -v FS='\n' '{
        v = f = s = h = ""; pkg = 0
        for (i = 1; i <= NF; i++) {
            if ($i == "Package: chatgpt")           pkg = 1
            else if (index($i, "Version: ")  == 1)  v = substr($i, 10)
            else if (index($i, "Filename: ") == 1)  f = substr($i, 11)
            else if (index($i, "Size: ")     == 1)  s = substr($i, 7)
            else if (index($i, "SHA256: ")   == 1)  h = substr($i, 9)
        }
        if (pkg && v != "" && f != "" && s != "" && h != "") print v, f, s, h
    }' | sort -V | tail -n 1
}

# APT metadata is external input. These fields later reach GitHub Actions
# outputs and shell steps, so accept only the grammar each field requires.
validate_stanza() {
    local deb_arch=$1 ver=$2 filename=$3 size=$4 sha256=$5 extra=${6:-}

    [ -z "$extra" ] || {
        echo "refresh-source: malformed $deb_arch Packages stanza" >&2
        return 1
    }
    [[ "$ver" =~ ^[0-9][-0-9A-Za-z.+:~]{0,127}$ ]] || {
        echo "refresh-source: invalid Version in $deb_arch Packages index" >&2
        return 1
    }
    [[ "$filename" =~ ^pool/main/c/chatgpt/chatgpt_[-0-9A-Za-z.+:~%]+_${deb_arch}\.deb$ ]] || {
        echo "refresh-source: invalid Filename in $deb_arch Packages index" >&2
        return 1
    }
    [[ "$size" =~ ^[1-9][0-9]*$ ]] || {
        echo "refresh-source: invalid Size in $deb_arch Packages index" >&2
        return 1
    }
    [[ "$sha256" =~ ^[0-9A-Fa-f]{64}$ ]] || {
        echo "refresh-source: invalid SHA256 in $deb_arch Packages index" >&2
        return 1
    }
}

declare -A ARCHES=([x86_64]=amd64 [aarch64]=arm64)
declare -A STANZAS=()

# Read both indexes before writing anything: the arches publish separately and
# can briefly disagree, and a mixed pin must never reach the manifest.
for arch in x86_64 aarch64; do
    deb_arch=${ARCHES[$arch]}
    stanza=$(curl -fsSL "$BASE/dists/stable/main/binary-$deb_arch/Packages" | parse_index)
    [ -n "$stanza" ] || {
        echo "refresh-source: no chatgpt stanza in the $deb_arch Packages index" >&2
        exit 1
    }
    STANZAS[$arch]=$stanza
done

ver_x86=${STANZAS[x86_64]%% *}
ver_arm=${STANZAS[aarch64]%% *}
if [ "$ver_x86" != "$ver_arm" ]; then
    echo "refresh-source: indexes disagree: x86_64=$ver_x86 aarch64=$ver_arm" >&2
    echo "refresh-source: upstream is likely mid-publish, retry later" >&2
    exit 1
fi

for arch in x86_64 aarch64; do
    deb_arch=${ARCHES[$arch]}
    read -r ver filename size sha256 extra <<<"${STANZAS[$arch]}"
    validate_stanza "$deb_arch" "$ver" "$filename" "$size" "$sha256" "$extra"
    echo ">> $arch: $ver  sha256=$sha256 size=$size"

    python3 - "$MANIFEST" "$deb_arch" "$BASE/$filename" "$sha256" "$size" <<'PY'
import re, sys
manifest, deb_arch, url, sha, size = sys.argv[1:6]
text = open(manifest).read()

# Match the url line directly followed by sha256 and size, so an url inside
# x-checker-data can never match. [ \t] not \s for the indent: \s also eats
# the preceding newline and leaves blank lines between the rewritten fields.
pattern = re.compile(
    r'^([ \t]*)url:\s*\S*_' + re.escape(deb_arch) + r'\.deb\n'
    r'[ \t]*sha256:\s*\S+\n'
    r'[ \t]*size:\s*\d+\n', re.M)

def repl(m):
    i = m.group(1)
    return f"{i}url: {url}\n{i}sha256: {sha}\n{i}size: {size}\n"

text, n = pattern.subn(repl, text, count=1)
if n != 1:
    sys.exit(f"refresh-source: could not locate the {deb_arch} source block")
open(manifest, 'w').write(text)
PY
done

echo ">> upstream version: $ver_x86"
"$SCRIPT_DIR/sync-version.sh" "$ver_x86"

echo ">> done. Review the diff before committing."

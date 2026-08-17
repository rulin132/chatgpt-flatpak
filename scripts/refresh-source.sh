#!/usr/bin/env bash
# Re-pin the manifest from upstream's APT index.
#
# Upstream runs a real APT repository: dists/stable/main/binary-{amd64,arm64}/
# Packages carries Version, Filename, Size and SHA256 for each arch, and the
# Filename points into pool/ where the path is versioned. Reading the index
# replaces the previous approach of downloading both ~380 MB .debs nightly to
# hash them, and pinning versioned pool/ URLs means the bytes behind a pin can
# never change out from under it, which is what the rolling latest/ URL did.
#
# Usage: scripts/refresh-source.sh [manifest.yaml]
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BASE=${DEB_REPO_BASE:-https://persistent.oaistatic.com/codex-app-prod/linux/deb}

manifests=(./*.ChatGPT.yaml)
MANIFEST=${1:-${manifests[0]}}

# stdin: a Packages index. stdout: "version filename size sha256" for the
# newest chatgpt stanza. An APT index may list several versions of a package;
# sort -V picks the highest rather than trusting stanza order.
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

declare -A ARCHES=([x86_64]=amd64 [aarch64]=arm64)
declare -A STANZAS=()

# Fetch and parse both indexes before writing anything. Upstream publishes the
# arches separately, so mid-publish they can briefly disagree; pinning a
# half-published release would fail ci-smoke on one arch with nothing to heal
# it until the next run. Failing before the first write means the manifest is
# never left with mixed pins and the nightly just retries tomorrow.
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
    read -r ver filename size sha256 <<<"${STANZAS[$arch]}"
    echo ">> $arch: $ver  sha256=$sha256 size=$size"

    python3 - "$MANIFEST" "$deb_arch" "$BASE/$filename" "$sha256" "$size" <<'PY'
import re, sys
manifest, deb_arch, url, sha, size = sys.argv[1:6]
text = open(manifest).read()

# Anchor on the one url line for this arch that is directly followed by
# sha256 and size, i.e. the extra-data source itself. The x-checker-data
# block has no such pair, so it can never match. [ \t] rather than \s for
# the indent: \s also eats the preceding newline, which turns the rewrite
# into url/sha256/size separated by blank lines.
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

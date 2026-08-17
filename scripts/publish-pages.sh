#!/usr/bin/env bash
# Assemble the GitHub Pages site: the signed OSTree repo plus the .flatpakrepo
# and .flatpakref descriptors, each with the public key embedded.
set -euo pipefail

: "${GPG_KEY_ID:?set GPG_KEY_ID}"
PAGES_URL=${PAGES_URL:?set PAGES_URL, e.g. https://rulin132.github.io/chatgpt-flatpak}
# basename, not `ls | sed`: the old form left the glob's "./" on the front, so
# the .flatpakref shipped Name=./io.github.rulin132.ChatGPT.
manifests=(./*.ChatGPT.yaml)
APP_ID=${APP_ID:-$(basename "${manifests[0]}" .yaml)}

rm -rf public && mkdir -p public
cp -a repo public/repo

KEY_B64=$(gpg --export "$GPG_KEY_ID" | base64 --wrap=0)

cat > public/chatgpt.flatpakrepo <<EOF
[Flatpak Repo]
Title=ChatGPT (unofficial Flatpak)
Comment=Community packaging of OpenAI's official Linux build
Description=Downloads OpenAI's own .deb at install time; no vendor binaries are redistributed.
Url=$PAGES_URL/repo/
Homepage=$PAGES_URL
Icon=$PAGES_URL/icon.png
SuggestRemoteName=chatgpt
GPGKey=$KEY_B64
EOF

cat > "public/$APP_ID.flatpakref" <<EOF
[Flatpak Ref]
Title=ChatGPT
Name=$APP_ID
Branch=master
Url=$PAGES_URL/repo/
SuggestRemoteName=chatgpt
RuntimeRepo=https://flathub.org/repo/flathub.flatpakrepo
IsRuntime=false
GPGKey=$KEY_B64
EOF

cp build-aux/icons/256.png public/icon.png

# Pages keeps serving the previous deploy for a while after the API reports
# success. Nothing else on the site can be used to tell the two apart: OSTree
# checksums are content-derived, so an identical rebuild republishes the same
# commit id, and a verifier that polls for reachability happily tests the old
# deploy and reports on bytes that were never published. This stamp is the only
# thing guaranteed to differ per run.
echo "${BUILD_ID:-unknown}" > public/build-id

cat > public/index.html <<EOF
<!doctype html><meta charset=utf-8>
<title>ChatGPT (unofficial Flatpak)</title>
<style>body{font:16px/1.6 system-ui;max-width:46rem;margin:4rem auto;padding:0 1rem}
pre{background:#f4f4f5;padding:.8rem;border-radius:6px;overflow-x:auto}</style>
<h1>ChatGPT desktop (unofficial Flatpak)</h1>
<p>For distributions OpenAI does not ship packages for: Fedora atomic
(Silverblue, Bluefin, Bazzite, Aurora, Kinoite), openSUSE Aeon/MicroOS, Arch,
NixOS, Alpine, Steam Deck.</p>
<pre>flatpak remote-add --user chatgpt $PAGES_URL/chatgpt.flatpakrepo
flatpak install --user chatgpt $APP_ID</pre>
<p>The app ships a <strong>sealed sandbox</strong>: no host filesystem access
and no host command execution. Grant a workspace explicitly:</p>
<pre>flatpak override --user --filesystem=~/code $APP_ID</pre>
<p>OpenAI's binary is downloaded from OpenAI at install time. This project does
not redistribute it and is not affiliated with OpenAI.</p>
EOF

echo "publish-pages: public/ ready ($(du -sh public | cut -f1))"

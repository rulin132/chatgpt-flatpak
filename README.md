# ChatGPT / Codex desktop — unofficial Flatpak

OpenAI ships the Linux desktop app as `.deb` and `.rpm` only. That covers Ubuntu,
Debian and traditional Fedora — and leaves out everything else. This repo packages
the **official** Linux build as a Flatpak for the distributions upstream doesn't
serve:

Fedora atomic (Silverblue, Bluefin, Bazzite, Aurora, Kinoite) · openSUSE
Aeon/MicroOS · Arch · NixOS · Alpine · Gentoo · Steam Deck · any immutable host
where layering an RPM is the wrong answer.

If you're on Ubuntu or traditional Fedora, use OpenAI's own signed apt/dnf repo
instead. This exists for the rest of us.

## Install

```sh
flatpak remote-add --user chatgpt https://OWNER.github.io/codex-flatpak/chatgpt.flatpakrepo
flatpak install --user chatgpt io.github.OWNER.ChatGPT
```

The app **starts with no access to your files.** Grant a workspace explicitly:

```sh
flatpak override --user --filesystem=~/code io.github.OWNER.ChatGPT
```

Other channels: a signed `.flatpak` bundle on each
[release](https://github.com/OWNER/codex-flatpak/releases) for sideloading, and
an OCI image at `ghcr.io/OWNER/chatgpt-flatpak` for
`flatpak install --image docker://…` (flatpak ≥ 1.17).

## How this differs from the other repackagers

| | this repo | AUR packages | DMG converters |
|---|---|---|---|
| Source | official Linux `.deb` | official `.deb` | macOS `.dmg`, converted |
| Chromium sandbox | **zypak** (renderers isolated) | inherits upstream | `--no-sandbox` by default |
| Update detection | nightly `flatpak-external-data-checker` → auto-PR | hand-bumped hashes | rebuild on each user's machine |
| Rolling-URL breakage | detected and re-pinned automatically | breaks until a human notices | n/a |
| Repo signing | GPG-signed | n/a | one ships an unsigned apt repo |
| Redistributes OpenAI bytes | **no** (`extra-data`) | no | one does |
| Layout change upstream | build fails in CI smoke test | silent | patches drift |

## Maintaining it

```sh
make rename GH_USER=<you>   # do this first — sets the app-id everywhere
make deps                   # runtimes, SDK, Electron BaseApp, linter
make hashes                 # pin sha256 + size from upstream, sync version
make icons                  # replace placeholder icons with the real ones
make install && make run
```

Then set three repository secrets — `GPG_PRIVATE_KEY`, `GPG_KEY_ID`,
and enable Pages (source: GitHub Actions).

### The update problem, and how it's solved

Upstream publishes to a rolling URL with no version in it:

```
https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_amd64.deb
```

Flatpak requires a pinned `sha256` for `extra-data`, so when OpenAI rotates
those bytes, every *new* install fails with `Invalid checksum for extra data`.
This is exactly what breaks the AUR packages that pin a hash against `latest/`.

`flatpak-external-data-checker` handles it: its `URLChecker` runs against every
`extra-data` source, and for `.deb` payloads it downloads the file and reads
`Version:` out of the control archive. Rotated bytes → source marked `BROKEN` →
`sha256` and `size` rewritten → PR opened. `update-check.yml` runs it nightly
and re-arms its own schedule (GitHub disables cron workflows after 60 days of
inactivity, which would otherwise kill the bot quietly).

The PR is **not** a rubber stamp: CI installs the new payload for real and runs
`apply_extra`. If upstream moves `app.asar` or renames the binary, that job
fails and `scripts/inspect-deb.sh` tells you what changed.

### If a build starts failing

```sh
scripts/inspect-deb.sh           # dump the upstream .deb layout
```

`apply_extra` deliberately fails closed — it locates `app.asar` and the main
ELF binary at install time rather than hardcoding upstream's paths, and aborts
with a specific message rather than producing a half-unpacked app.

## Sandbox

Sealed by default: **no** `--filesystem=host`, **no**
`--talk-name=org.freedesktop.Flatpak`. The app cannot read your home directory
or execute commands on the host until you grant it. Read
[docs/SECURITY.md](docs/SECURITY.md) before widening that — particularly the
part about why this is not a trust boundary you should put client work behind.

## Legal

The `extra-data` source type means the vendor binary is downloaded from OpenAI
by *your* machine at install time. This repository hosts no OpenAI software and
redistributes none. The MIT licence covers the packaging — manifest, scripts,
metadata — and grants no rights to OpenAI software or services. Not affiliated
with OpenAI. You need your own ChatGPT account and must comply with OpenAI's
terms.

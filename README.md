# ChatGPT / Codex Desktop Flatpak

This directory contains the Flatpak manifest and build configuration for Claude Desktop, allowing you to run Claude on any Linux distribution (not just Red Hat and Debian based ones). This repo packages the **official** Linux build as a Flatpak, allowing those on Fedora atomic (Silverblue, Bluefin, Bazzite, Aurora, Kinoite) · openSUSE
Aeon/MicroOS · Arch · NixOS · Alpine · Gentoo · Steam Deck · basically any immutable host to be able to run this application.

## Install

```sh
flatpak remote-add --user chatgpt https://rulin132.github.io/codex-flatpak/chatgpt.flatpakrepo
flatpak install --user chatgpt io.github.rulin132.ChatGPT
```

If you want access to the Desktop, please use this commend.

```sh
flatpak override --user --filesystem=~/code io.github.rulin132.ChatGPT
```

Also available as an OCI image at `ghcr.io/rulin132/chatgpt-flatpak`

```sh
flatpak install --user --image docker://ghcr.io/rulin132/chatgpt-flatpak:latest
```

## Maintaining it
I'm not the only one that can maintain it, you can too, simple as forking this repository and running the following.

```sh
make rename GH_USER=<you>   # do this first, sets the app-id everywhere
make deps                   # runtimes, SDK, Electron BaseApp, linter
make hashes                 # pin sha256 + size from upstream, sync version
make icons                  # replace placeholder icons with the real ones
make install && make run
```

Then set two repository secrets, `GPG_PRIVATE_KEY` and `GPG_KEY_ID`,
and enable Pages (source: GitHub Actions).

## Known issues

**The avatar overlay renders as an opaque box on Wayland.** Upstream draws the
"pet" in a second, frameless, transparent window, and this Electron build does
not composite window transparency on the Wayland Ozone backend. Measured against
26.810.52044: broken on Wayland, broken on Wayland with Vulkan disabled, correct
on XWayland. It is an upstream platform bug, not something this packaging causes.

If it bothers you, opt into XWayland per-install:

```sh
flatpak override --user --socket=x11 io.github.rulin132.ChatGPT
```

That is a real trade, not a free fix. XWayland costs you native Wayland scaling
and input handling, and X11 is a shared server, so the app can observe other X11
clients. Revert with `--nosocket=x11`.

**Do not "fix" this by adding `--socket=x11` to the manifest.** The launcher
passes `--ozone-platform-hint=auto`, and this Electron prefers X11 whenever
`DISPLAY` is set. Granting the socket therefore moves *every* user to XWayland
rather than offering a fallback. If that ever becomes desirable, the hint has to
be pinned to `wayland` in the same change.

**A blank window is not fixed with `--disable-gpu`.** Use `CHATGPT_DISABLE_GPU=1`,

## Legal

The `extra-data` source type means the vendor binary is downloaded from OpenAI by *your* machine at install time. This repository hosts no OpenAI software and redistributes none. The MIT licence covers the packaging (manifest, scripts, metadata) and grants no rights to OpenAI software or services. Not affiliated with OpenAI. You need your own ChatGPT account and must comply with OpenAI's terms.

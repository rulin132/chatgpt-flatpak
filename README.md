# ChatGPT / Codex Desktop Flatpak

This repo packages the **official** ChatGPT / Codex Linux build as a Flatpak
that starts with no access to your files, and gives it back one directory at a
time. Codex executes code. This exists so the thing running commands cannot
read `~/.ssh`, `~/.aws`, your browser profiles or your work repos unless you
say so.

**It trades ease of use for that, and the trade is real.** You configure what it
can see, the desktop avatar does not render, and it is not on your `PATH`. If
you want the app rather than the confinement, install it on the host instead.
On Bluefin, Bazzite and Aurora that is one command, it updates itself, and there
is nothing to configure:

```sh
brew install --cask ublue-os/experimental-tap/chatgpt-linux
```

That unpacks OpenAI's rpm into `~/.local` and runs it as you, with your full
user rights. For most people that is the right answer. Everything below is for
the people it is not.

## Install

```sh
flatpak remote-add --user chatgpt https://rulin132.github.io/chatgpt-flatpak/chatgpt.flatpakrepo
flatpak install --user chatgpt io.github.rulin132.ChatGPT
```

The app starts with **no access to your files.** Grant a directory explicitly,
for example your Desktop:

```sh
flatpak override --user --filesystem=~/Desktop io.github.rulin132.ChatGPT
```

Also published as an OCI image at `ghcr.io/rulin132/chatgpt-flatpak`, for
mirroring and offline installs. Fetch it with a registry client first: pointing
flatpak straight at `docker://` returns 401, because it does not complete the
anonymous token exchange GHCR requires, even though the package is public.

```sh
skopeo copy docker://ghcr.io/rulin132/chatgpt-flatpak:latest oci:oci-chatgpt:latest
flatpak install --user --image oci:oci-chatgpt:latest
```

That image is 3 MB. It carries the packaging alone; the application itself is
still downloaded from OpenAI at install time, exactly as with the repo above.

## Sandbox

Sealed by default: no `--filesystem=host`, no
`--talk-name=org.freedesktop.Flatpak`. The app cannot read your home directory
or run commands on your host until you grant it.

Renderers stay isolated under zypak rather than `--no-sandbox`, which is what
the other Flatpak repackagings of this app use. `--no-sandbox` does not disable
"a" sandbox, it removes renderer isolation entirely, so any compromised web
content inherits every permission the flatpak holds.

Go further and deny X11 outright. `--socket=fallback-x11` only grants X11 when
there is no Wayland, so on a Wayland session it is already unused; denying it
means an X11 session, or a change in how the launcher picks its backend, cannot
hand X11 back. X11 is a shared server, where any client can read other clients'
input and window contents.

```sh
flatpak override --user --nosocket=x11 --nosocket=fallback-x11 io.github.rulin132.ChatGPT
```

The app runs and authenticates normally with both denied. The cost is that on an
X11-only machine it will not start at all.

Review or undo what you have granted:

```sh
flatpak override --user --show io.github.rulin132.ChatGPT
flatpak override --user --reset io.github.rulin132.ChatGPT
```

Read [docs/SECURITY.md](docs/SECURITY.md) before widening it, particularly the
part about why this is not a trust boundary you should put client work behind.

## Maintaining it
I'm not the only one that can maintain it, you can too, simple as forking this repository and running the following.

```sh
make rename GH_USER=<you>   # do this first, sets the app-id everywhere
make deps                   # runtimes, SDK, Electron BaseApp, linter
make hashes                 # pin sha256 + size from upstream, sync version
make icons                  # replace placeholder icons with the real ones
make install && make run
```

### Repository setup

None of this is optional, and nothing here is created for you.

**Secrets**

- `GPG_PRIVATE_KEY` and `GPG_KEY_ID`. Flatpak refuses system-wide installs of an
  extra-data app from a remote that is not gpg-verified, so publishing without
  these produces a repo nobody can install system-wide.
- `AUTOMATION_TOKEN`, a personal access token with `contents: write` and
  `pull-requests: write`. The nightly update check uses it instead of
  `GITHUB_TOKEN` because GitHub does not start workflow runs for anything
  `GITHUB_TOKEN` does: a PR opened with it arrives with zero checks. The
  workflow fails on the first step with a clear message if this is unset.

**Settings**

- Pages, source: GitHub Actions.
- Make the GHCR package public. A package created by the first push defaults to
  private, so the `docker://ghcr.io/...` install above returns 401 for everyone
  until you change it under Packages, package settings, change visibility.
- Allow auto-merge, under General. Without it the auto-merge step errors out.
- Branch protection on `main` requiring these four checks: `shellcheck`,
  `lint`, `build (x86_64, ubuntu-latest)`, `build (aarch64, ubuntu-24.04-arm)`.

**Labels and variables**

- A label named `automated`. `gh pr create --label` errors when the label does
  not exist, so without it the nightly job opens no PR at all.
- Repository variable `AUTO_UPDATE`. Unset means off, which is how this ships.
  Set it to `on` to let the nightly refresh PR auto-merge once those four
  checks pass, and to let a manifest change on `main` publish a release. Unset
  it to stop the whole pipeline from the GitHub UI in seconds, with no commit
  and nothing to revert.

### The nightly refresh

`update-check.yml` runs `scripts/refresh-source.sh` at 04:17 UTC. Upstream
publishes a real APT repository, so the script reads `Version`, `Filename`,
`Size` and `SHA256` for both architectures from the `Packages` indexes, a few
kilobytes, rewrites the manifest's versioned `pool/` pins, bumps the AppStream
release entry, and opens a PR on `chore/upstream-refresh` labelled `automated`.
Versioned pins cannot rot silently: when upstream deletes an old `.deb` from
`pool/`, installs fail cleanly on 404 until the refresh PR lands. If the
repository has been quiet for 50 days the job also commits to
`chore/keepalive`, because GitHub disables scheduled workflows after 60 days
of inactivity.

## Autostart

To start it at login:

```sh
cp ~/.local/share/flatpak/exports/share/applications/io.github.rulin132.ChatGPT.desktop ~/.config/autostart/
```

It opens with its window. Starting minimized to the tray would need a flag from
the app itself, which upstream has not added.

## Known issues

If something misbehaves, capture the log first:

```sh
flatpak run io.github.rulin132.ChatGPT 2>&1 | tee /tmp/chatgpt.log
```

**The avatar overlay renders as an opaque box.** The pet lives in frameless
transparent windows, and those go opaque when Chromium inside the sandbox loses
hardware GL and degrades to software rendering. The usual cause on NVIDIA: the
host driver updated before the matching `org.freedesktop.Platform.GL.nvidia`
extension, and flatpak mounts that extension only on an exact version match, so
the sandbox is left with no usable driver. With a healthy GL stack this
composited correctly (verified against 26.810.52044 on GNOME with NVIDIA, in
hardware, SwiftShader, and no-GL modes), so earlier revisions of this document
blamed the mismatch alone.

A matched stack is not a guarantee. The box also reproduced with the driver
and GL extension in sync (NVIDIA 610.43.03 against both 26.810.52044 and
26.814.41957, with the rest of the app rendering in hardware), alongside a
"'--ozone-platform=wayland' is not compatible with Vulkan" error at startup.
Upstream fixed that case in 26.818 on the same driver, so it was the app's
Vulkan use on Wayland, and it can regress the same way again. If the box is
back on a matched stack, suspect the app version first.

**Diagnosis and fix.** The launcher warns on stderr when it sees an NVIDIA
device with no `GL/nvidia-*` extension mounted. To check by hand, compare
`flatpak list --runtime | grep GL.nvidia` against the host driver version from
`nvidia-smi`. Then `flatpak update` and restart the app. On a hybrid
NVIDIA-plus-integrated laptop that renders on the iGPU via Mesa, the warning
can fire while everything looks correct; if the pet is drawing fine, ignore it.
If the warning stays quiet, the versions match, and the box persists, you are
in the second case: it heals with an app update, not anything local. Do not
reach for X11 (below).

**Prevention.** On image-based hosts the driver lands at reboot but the GL
extension lands on `flatpak update`, so the mismatch window is an update-order
problem. Keep flatpak auto-updates on (GNOME Software, or a daily
`flatpak update -y` timer) and the window stays effectively closed.

**Do not add `--socket=x11` to the manifest chasing rendering bugs.** The
launcher passes `--ozone-platform-hint=auto`, and this Electron prefers X11
whenever `DISPLAY` is set. Granting the socket therefore moves *every* user to
XWayland rather than offering a fallback, and X11 is a shared server, so the
app could watch other X11 clients' input and windows. If it ever becomes
desirable, the hint has to be pinned to `wayland` in the same change.

**A blank window is not fixed with `--disable-gpu`.** That leaves Chromium with
no rasteriser and opens no window at all. Use `CHATGPT_DISABLE_GPU=1`, which
routes ANGLE at the bundled SwiftShader instead.

## Uninstalling

```sh
flatpak uninstall --user io.github.rulin132.ChatGPT
```

That keeps your data and the cached Codex runtime in
`~/.var/app/io.github.rulin132.ChatGPT`, which runs to several GB. To remove
that as well:

```sh
flatpak uninstall --user --delete-data io.github.rulin132.ChatGPT
```

## Legal

The `extra-data` source type means the vendor binary is downloaded from OpenAI by *your* machine at install time. This repository hosts and redistributes no OpenAI executable code. It does commit seven application icons in `build-aux/icons/`, downscaled from the icon in upstream's `.deb`, because icons and AppStream metadata must exist at build time while the payload only arrives at install time. The MIT licence covers the packaging (manifest, scripts, metadata) and grants no rights to OpenAI software or services. Not affiliated with OpenAI. You need your own ChatGPT account and must comply with OpenAI's terms.

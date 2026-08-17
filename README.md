# ChatGPT / Codex Desktop Flatpak

This repo packages the **official** ChatGPT / Codex Linux build as a Flatpak, so
you can run it on any distribution, not just the Red Hat and Debian based ones
OpenAI ships packages for. That means Fedora atomic (Silverblue, Bluefin,
Bazzite, Aurora, Kinoite) · openSUSE Aeon/MicroOS · Arch · NixOS · Alpine ·
Gentoo · Steam Deck · basically any immutable host.

## Install

```sh
flatpak remote-add --user chatgpt https://rulin132.github.io/codex-flatpak/chatgpt.flatpakrepo
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
the other Linux repackagers of this app use. `--no-sandbox` does not disable
"a" sandbox, it removes renderer isolation entirely, so any compromised web
content inherits every permission the flatpak holds.

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
publishes to a rolling `latest` URL, so the bytes behind our pinned sha256
rotate with no version change. The job re-pins sha256 and size for both
architectures, bumps the AppStream release entry from the `.deb` control file,
and opens a PR on `chore/upstream-refresh` labelled `automated`. If the
repository has been quiet for 50 days it also commits to `chore/keepalive`,
because GitHub disables scheduled workflows after 60 days of inactivity.

## Known issues

If something misbehaves, capture the log first:

```sh
flatpak run io.github.rulin132.ChatGPT 2>&1 | tee /tmp/chatgpt.log
```

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

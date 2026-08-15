# Sandbox posture

## What this package does

**zypak, not `--no-sandbox`.** Electron's SUID sandbox helper cannot work inside
a flatpak. The common workaround in the existing repackagers is to pass
`--no-sandbox`, which does not disable "a" sandbox — it removes renderer and GPU
process isolation entirely. From then on, any compromised web content inherits
*everything the flatpak holds*: the network share, every `--filesystem=` grant,
every `--talk-name=`. For an app that stores an account credential and reads
source code, that collapses two boundaries at once.

`org.electronjs.Electron2.BaseApp` ships [zypak](https://github.com/refi64/zypak),
which intercepts Chromium's sandbox calls and runs each renderer in a nested
flatpak sub-sandbox instead. `apply_extra` installs `stub_sandbox` over
upstream's `chrome-sandbox` to satisfy Chromium's presence check.
`--require-version=1.8.2` is in `finish-args` because zypak's faster spawn
strategy needs `expose-pids`.

**Sealed permissions.** Deliberately absent from `finish-args`:

| Not granted | Why |
|---|---|
| `--filesystem=host` / `=home` | the app sees no user files until you say so |
| `--talk-name=org.freedesktop.Flatpak` | this permits `flatpak-spawn --host`, i.e. arbitrary command execution outside the sandbox. Flathub treats it as an exception-requiring rule. VS Code holds it, plus `--filesystem=host` and `--allow=devel` — which is why a flatpak'd VS Code is not meaningfully confined |
| `--device=all` | `--device=dri` covers GPU without handing over every USB device |

Grant the minimum you need, per directory:

```sh
flatpak override --user --filesystem=~/code/thisproject io.github.OWNER.ChatGPT
flatpak override --user --show io.github.OWNER.ChatGPT     # review
flatpak override --user --reset io.github.OWNER.ChatGPT    # start over
```

The trade is real: with a sealed sandbox the agent can only run commands against
the tools inside the runtime, not your host toolchain. If you widen it to
`--talk-name=org.freedesktop.Flatpak` to get host execution back, you have
opted out of the sandbox — do that knowingly, not by copying a snippet.

## What this package does not do

**No network egress filtering.** `--share=network` is all-or-nothing; flatpak
has no destination-level control and the request for it
([flatpak#3054](https://github.com/flatpak/flatpak/issues/3054)) was closed.
Network access additionally exposes host services listening on abstract unix
sockets. If you need default-deny egress you must build it outside flatpak — a
dedicated network namespace around the launch, or nftables matching the app's
`app-flatpak-*.scope` cgroup.

**Not a trust boundary for other people's code.** Flatpak 1.17.4 (Apr 2026)
fixed a complete sandbox escape to host code execution; 1.19.0 (11 Aug 2026)
fixed ten more, including a path traversal in *extra-data extraction*
specifically. The flatpak boundary is a good usability and blast-radius
boundary. It is not where you should place a credential or client-data
boundary. For work under a client engagement, run the agent in a container cell
with its own credentials and a default-deny egress policy, and keep this
flatpak for personal use.

**Every install reaches OpenAI's CDN directly.** `extra-data` is fetched
per-machine at install and repair time; it cannot be baked into an OS image. On
a fleet with an egress policy, mirror the `.deb` to an internal artifact store
and repoint `url:` — which also gives you a stable hash and removes the rolling-URL
problem entirely.

## Supply chain

- The vendor payload is pinned by `sha256` + `size` and verified by flatpak
  before `apply_extra` runs. A rotated artifact fails the install rather than
  installing unknown bytes.
- The repo is GPG-signed. Signing is not cosmetic here: flatpak refuses
  system-wide installs of extra-data apps from sources that are not
  gpg-verified.
- `apply_extra` fails closed on unexpected layout instead of proceeding.
- Nothing from OpenAI is rebuilt, patched into a binary artifact, or re-hosted.

## Reporting

Packaging issues: open an issue here. Bugs in the ChatGPT application itself go
to OpenAI — reproduce them with the official `.deb` first, since this packaging
does change the process sandbox and the filesystem view.

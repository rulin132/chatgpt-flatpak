# Contributing

Thanks for helping improve the ChatGPT / Codex Desktop Flatpak. This repository
packages the official Linux application; it does not develop the ChatGPT or
Codex application itself.

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Before opening an issue

Search existing issues first. Packaging issues belong here, including problems
with installation, Flatpak permissions, the launcher, the manifest, updates,
or behaviour that differs from the official Linux package.

If the same problem occurs with OpenAI's official Linux package, report it to
[OpenAI Support](https://help.openai.com/) instead. Do not open public issues
for vulnerabilities or sensitive account information; follow the
[security policy](docs/SECURITY.md).

When reporting a packaging bug, use the bug report form and include the exact
commands needed to reproduce it, relevant logs, your Flatpak version, and any
overrides you have granted. Remove tokens, account details, file paths, and
other sensitive data from logs before posting them.

## Set up a development environment

Fork and clone the repository, then create a branch for one focused change.
The development commands assume a Linux system with Flatpak installed:

```sh
make deps
make install
make run
```

`make deps` installs the required Freedesktop runtime, SDK, Electron BaseApp,
and Flatpak Builder for the current user. `make install` builds the pinned
upstream package and installs it from a local Flatpak repository.

If you are adapting the repository under a different GitHub account, run
`make rename GH_USER=<your-github-username>` before the other setup commands.
Use `make hashes` and `make icons` only when intentionally updating the
upstream version or its extracted artwork; both commands rewrite tracked files.

## Make a change

- Keep each pull request focused and explain why the change is needed.
- Preserve the sealed-by-default permission model. New filesystem, device,
  socket, or D-Bus permissions need a specific threat and trade-off analysis.
- Do not add `--no-sandbox`, broad host or home access, or
  `--talk-name=org.freedesktop.Flatpak`; these defeat core protections described
  in the [security policy](docs/SECURITY.md).
- Add or update tests when changing scripts, payload layout assumptions, version
  synchronisation, launcher behaviour, or repository publishing logic.
- Update the README, AppStream metadata, and comments when user-visible
  behaviour or maintenance procedures change.
- Do not commit downloaded application payloads, build outputs, repositories,
  credentials, signing keys, or account data.

## Test the change

Run the checks that apply to your change before opening a pull request:

```sh
shellcheck -x scripts/*.sh tests/*.sh build-aux/apply_extra \
  build-aux/launcher.sh build-aux/codex-flatpak-wrapper

for test_script in tests/test-*.sh; do
  "$test_script" || exit 1
done

make lint
make build
```

The full build downloads the pinned upstream package and can take substantially
longer than the shell tests. GitHub Actions repeats the shell checks and tests,
lints the manifest, and builds and smoke-tests both x86_64 and aarch64.

For changes affecting runtime behaviour, also install and exercise the build
locally. Include the manual scenarios you tested in the pull request.

## Open a pull request

Complete the pull request template, link related issues, and call out security
or permission changes explicitly. Screenshots are useful for visible changes;
terminal output is more useful for installation and launch failures.

All four protected checks must pass: `shellcheck`, `lint`,
`build (x86_64, ubuntu-latest)`, and
`build (aarch64, ubuntu-24.04-arm)`. Review feedback may ask for a smaller
change, more test coverage, or clearer documentation before merge.

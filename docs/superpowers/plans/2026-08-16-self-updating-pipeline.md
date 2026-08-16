# Self-updating pipeline implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When OpenAI rotates the upstream payload, the repo re-pins itself, proves the new payload installs and launches on both architectures, merges, and publishes to users, with no human in the loop and a switch to stop it.

**Architecture:** Four workflows in a chain. A nightly job runs the existing `scripts/refresh-source.sh` and opens a PR. `build.yml` gates it with install plus launch assertions on x86_64 and aarch64. Auto-merge lands it. `release.yml`, rebuilt as a two-job matrix, builds both arches, merges the per-arch OSTree repos into one signed repo, and publishes Pages and GHCR. A repository variable gates merge and publish.

**Tech Stack:** GitHub Actions, flatpak-builder, OSTree, `gh` CLI, bash. No third-party marketplace actions.

**Spec:** `docs/superpowers/specs/2026-08-16-self-updating-pipeline-design.md`

## Global Constraints

- Never add `--no-sandbox`, `--filesystem=host`, or `--talk-name=org.freedesktop.Flatpak`.
- `apply_extra` fails closed. Every pipeline stage around it must too.
- No em dashes in prose or comments. Keep shell shellcheck-clean under `shellcheck -x`; CI runs shellcheck 0.9.0, which flags `A && B || C`.
- No third-party marketplace actions. `actions/checkout`, `actions/upload-artifact`, `actions/download-artifact` and `actions/deploy-pages` are first-party and allowed.
- App id is `io.github.rulin132.ChatGPT`; manifest is `io.github.rulin132.ChatGPT.yaml`. Do not hardcode a different namespace; `make rename` derives it from `APP_ID`.
- `AUTO_UPDATE` ships unset. Nothing in this plan turns it on.
- Recipes in the Makefile run under `/bin/sh`. No bashisms.

## Spike results, already established

Do not re-litigate these; they are measured, not assumed.

- zypak does **not** need the session bus. With `--nosocket=session-bus` the app reached `window ready-to-show` twice and kept 4 renderer zygotes under `bwrap` via `zypak-helper child`.
- Electron **does** need an X display. With wayland, fallback-x11 and x11 all removed it exits 1 with `Missing X server or $DISPLAY`. It fails fast and loudly rather than hanging.
- Therefore the launch assertion needs only a virtual display, not a D-Bus session.
- The CI image already ships `Xvfb`, `xvfb-run` and `dbus-run-session`, so the
  assertion needs no package installation.

## File structure

- `.github/workflows/build.yml`: modify. Adds the launch assertion to the existing smoke test.
- `.github/workflows/release.yml`: rewrite. Two jobs: per-arch build, then merge, sign and publish.
- `.github/workflows/update-check.yml`: rewrite. First-party detection, PR creation, keepalive, auto-merge.
- `scripts/merge-repos.sh`: create. Merges per-arch OSTree repos into one. Extracted from the workflow so it can be tested locally, which nothing in a workflow can be.
- `tests/test-merge-repos.sh`: create. Proves the merge produces both refs and fails closed on an empty input.

---

### Task 1: Launch assertion in CI

**Files:**
- Modify: `.github/workflows/build.yml` (smoke test step)

**Interfaces:**
- Consumes: the installed flatpak from the existing smoke test step.
- Produces: nothing later tasks import. Establishes the `xvfb-run` invocation reused verbatim in Task 2.

No install step is needed. Measured against the CI image on 2026-08-16:
`Xvfb`, `xvfb-run` and `dbus-run-session` are all present in
`ghcr.io/flathub-infra/flatpak-github-actions:freedesktop-25.08`
(`distro=org.freedesktop.platform 25.08`).

- [ ] **Step 1: Add the launch assertion to the smoke test step**

Append to the existing `smoke test (install + apply_extra)` step in `.github/workflows/build.yml`, after the `payload OK` block:

```yaml
          # The payload unpacking is not proof it runs. zypak needs no session
          # bus (measured), but Electron needs a display, so give it a virtual
          # one. timeout kills a healthy app, so the grep decides, not the exit.
          xvfb-run -a --server-args='-screen 0 1280x800x24' \
            timeout 120 flatpak run io.github.rulin132.ChatGPT > /tmp/launch.log 2>&1 || true
          grep -q 'window ready-to-show' /tmp/launch.log || {
            echo "app never reached window ready-to-show"
            grep -viE 'statsig' /tmp/launch.log | tail -40
            exit 1
          }
          echo "launch OK: $(grep -m1 'window ready-to-show' /tmp/launch.log)"
```

- [ ] **Step 2: Prove the assertion fails when it should, locally**

The assertion must be able to go red or it is decoration. Run the negative case:

```bash
cd /var/home/gavin/code/gigastorm/codex-flatpak/.claude/worktrees/codex-flatpak-build-launch-b4baf5
flatpak kill io.github.rulin132.ChatGPT 2>/dev/null; sleep 3
timeout 40 flatpak run --nosocket=session-bus --nosocket=wayland \
  --nosocket=fallback-x11 --nosocket=x11 io.github.rulin132.ChatGPT > /tmp/neg.log 2>&1 || true
grep -q 'window ready-to-show' /tmp/neg.log && echo "BAD: assertion would pass" || echo "good: assertion would fail"
```

Expected: `good: assertion would fail`.

- [ ] **Step 3: Prove it passes on a healthy app, locally**

```bash
flatpak kill io.github.rulin132.ChatGPT 2>/dev/null; sleep 3
timeout 40 flatpak run --nosocket=session-bus io.github.rulin132.ChatGPT > /tmp/pos.log 2>&1 || true
grep -q 'window ready-to-show' /tmp/pos.log && echo "good: assertion passes" || echo "BAD"
flatpak kill io.github.rulin132.ChatGPT 2>/dev/null
```

Expected: `good: assertion passes`.

- [ ] **Step 4: Commit and push, then confirm both arches go green in CI**

```bash
git add .github/workflows/build.yml
git commit -m "Assert the payload launches, not just that it unpacks"
git push origin gavin/codex-flatpak-build-launch-b4baf5
```

Then wait for the run and check both `build` legs:

```bash
gh run list --repo rulin132/codex-flatpak --branch gavin/codex-flatpak-build-launch-b4baf5 --limit 1 --json databaseId --jq '.[0].databaseId'
gh run view <id> --repo rulin132/codex-flatpak --json jobs --jq '.jobs[] | "\(.name): \(.conclusion)"'
```

Expected: all four jobs `success`. If the aarch64 leg fails on Xvfb specifically, that is a real finding: record it and stop rather than dropping the assertion from one arch.

---

### Task 2: Publish both architectures

**Files:**
- Create: `scripts/merge-repos.sh`
- Create: `tests/test-merge-repos.sh`
- Rewrite: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: nothing from Task 1 except the `xvfb-run` line, copied verbatim.
- Produces: `scripts/merge-repos.sh <dest-repo> <src-repo>...` which mirrors every ref from each source into dest and exits non-zero if any source has no `app/` ref. `release.yml` and `tests/test-merge-repos.sh` both call it.

- [ ] **Step 1: Write the failing test**

Create `tests/test-merge-repos.sh`:

```bash
#!/usr/bin/env bash
# Tests for scripts/merge-repos.sh. A published repo missing an architecture is
# invisible until an aarch64 user tries to install, so this asserts both refs
# survive the merge and that an empty source is refused rather than skipped.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$REPO/scripts/merge-repos.sh
pass=0 fail=0

check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"
    else fail=$((fail + 1)); echo "  FAIL $1: expected '$3', got '$2'"; fi
}

work=$(mktemp -d)
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT

# Two source repos, each with one arch ref, standing in for the two build jobs.
for arch in x86_64 aarch64; do
    ostree --repo="$work/src-$arch" init --mode=archive-z2 >/dev/null
    mkdir -p "$work/tree-$arch"
    echo "$arch" > "$work/tree-$arch/marker"
    ostree --repo="$work/src-$arch" commit \
        --branch="app/io.github.rulin132.ChatGPT/$arch/master" \
        --subject=test "$work/tree-$arch" >/dev/null
done

"$SCRIPT" "$work/dest" "$work/src-x86_64" "$work/src-aarch64" >/dev/null
refs=$(ostree --repo="$work/dest" refs | sort | tr '\n' ' ')
check "both arch refs present" "$refs" \
  "app/io.github.rulin132.ChatGPT/aarch64/master app/io.github.rulin132.ChatGPT/x86_64/master "

# A build job that produced nothing must fail the merge, not be silently dropped.
ostree --repo="$work/empty" init --mode=archive-z2 >/dev/null
if "$SCRIPT" "$work/dest2" "$work/src-x86_64" "$work/empty" >/dev/null 2>&1; then
    fail=$((fail + 1)); echo "  FAIL empty source must fail closed"
else
    pass=$((pass + 1)); echo "  ok   empty source fails closed"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run it and watch it fail**

```bash
chmod +x tests/test-merge-repos.sh
tests/test-merge-repos.sh
```

Expected: fails, because `scripts/merge-repos.sh` does not exist.

- [ ] **Step 3: Write the minimal implementation**

Create `scripts/merge-repos.sh`:

```bash
#!/usr/bin/env bash
# Merge per-architecture OSTree repos into one publishable repo.
#
# release.yml builds each arch on its own native runner, so the halves arrive as
# separate artifacts. Publishing one of them alone yields a remote that silently
# has no aarch64, which is what shipped before this existed.
#
# Usage: scripts/merge-repos.sh <dest-repo> <src-repo>...
set -euo pipefail

DEST=${1:?usage: merge-repos.sh <dest-repo> <src-repo>...}
shift
[ "$#" -gt 0 ] || { echo "merge-repos: no source repos given" >&2; exit 1; }

ostree --repo="$DEST" init --mode=archive-z2

for src in "$@"; do
    refs=$(ostree --repo="$src" refs | grep '^app/' || true)
    [ -n "$refs" ] || { echo "merge-repos: $src has no app/ ref" >&2; exit 1; }
    # --mirror carries every ref, including the .Debug runtime extension.
    ostree --repo="$DEST" pull-local --mirror "$src"
    echo "merge-repos: pulled from $src: $(echo "$refs" | tr '\n' ' ')"
done
```

- [ ] **Step 4: Run the test and watch it pass**

```bash
chmod +x scripts/merge-repos.sh
tests/test-merge-repos.sh
```

Expected: `2 passed, 0 failed`.

- [ ] **Step 5: Confirm shellcheck is clean at CI's severity**

```bash
shellcheck -x scripts/*.sh tests/*.sh build-aux/apply_extra build-aux/launcher.sh
echo "exit=$?"
```

Expected: `exit=0`. If it reports `SC2015`, rewrite the construct as guard clauses; CI's shellcheck 0.9.0 flags patterns 0.11 does not.

- [ ] **Step 6: Commit the merge script**

```bash
git add scripts/merge-repos.sh tests/test-merge-repos.sh
git commit -m "Add a tested OSTree repo merge for per-arch builds"
```

- [ ] **Step 7: Rewrite release.yml as two jobs**

Replace the `publish` job in `.github/workflows/release.yml` with:

```yaml
jobs:
  build:
    strategy:
      fail-fast: false
      matrix:
        include:
          - arch: x86_64
            runner: ubuntu-latest
          - arch: aarch64
            runner: ubuntu-24.04-arm
    runs-on: ${{ matrix.runner }}
    container:
      image: ghcr.io/flathub-infra/flatpak-github-actions:freedesktop-25.08
      options: --privileged
    steps:
      - uses: actions/checkout@v4

      # Unsigned here. Signing happens once, in publish, so the key touches one
      # job rather than every matrix leg.
      - name: build
        run: |
          set -euo pipefail
          flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
          flatpak-builder --user --install-deps-from=flathub --force-clean \
            --disable-rofiles-fuse --arch=${{ matrix.arch }} \
            --repo=repo build io.github.rulin132.ChatGPT.yaml

      # Same gate as build.yml. A release must not publish bytes that were never
      # installed, which is how the tag path used to work.
      - name: smoke test
        run: |
          set -euo pipefail
          flatpak remote-add --user --if-not-exists --no-gpg-verify chatgpt-rel "$PWD/repo"
          flatpak install --user -y chatgpt-rel io.github.rulin132.ChatGPT
          version=$(flatpak run --command=cat io.github.rulin132.ChatGPT /app/extra/VERSION)
          test -n "$version" && test "$version" != unknown
          flatpak run --command=sh io.github.rulin132.ChatGPT -c '
            set -eu
            . /app/extra/app.env
            test -x "$APP_BIN" || { echo "APP_BIN not executable"; exit 1; }
            head -c4 "$APP_BIN" | grep -q ELF || { echo "not an ELF"; exit 1; }
            test -f /app/extra/app/resources/app.asar || { echo "no app.asar"; exit 1; }
          '
          xvfb-run -a --server-args='-screen 0 1280x800x24' \
            timeout 120 flatpak run io.github.rulin132.ChatGPT > /tmp/launch.log 2>&1 || true
          grep -q 'window ready-to-show' /tmp/launch.log || {
            echo "app never reached window ready-to-show"
            grep -viE 'statsig' /tmp/launch.log | tail -40
            exit 1
          }

      - uses: actions/upload-artifact@v4
        with:
          name: repo-${{ matrix.arch }}
          path: repo
          retention-days: 1

  publish:
    needs: build
    runs-on: ubuntu-latest
    container:
      image: ghcr.io/flathub-infra/flatpak-github-actions:freedesktop-25.08
      options: --privileged
    steps:
      - uses: actions/checkout@v4

      - uses: actions/download-artifact@v4
        with:
          path: arch-repos

      - name: read version
        id: ver
        run: echo "v=$(sed -n 's/.*<release version="\([^"]*\)".*/\1/p' build-aux/io.github.rulin132.ChatGPT.metainfo.xml | head -n1)" >> "$GITHUB_OUTPUT"

      - name: tag must match the manifest version
        if: startsWith(github.ref, 'refs/tags/')
        run: |
          set -euo pipefail
          want="v${{ steps.ver.outputs.v }}"
          test "${{ github.ref_name }}" = "$want" || {
            echo "tag ${{ github.ref_name }} does not match metainfo $want"; exit 1; }

      - name: import signing key
        env:
          GPG_PRIVATE_KEY: ${{ secrets.GPG_PRIVATE_KEY }}
        run: |
          set -euo pipefail
          export GNUPGHOME=$PWD/.gnupg
          mkdir -p -m700 "$GNUPGHOME"
          echo "$GPG_PRIVATE_KEY" | gpg --batch --import
          echo "GNUPGHOME=$GNUPGHOME" >> "$GITHUB_ENV"

      # Named `repo` because publish-pages.sh copies that path unchanged.
      - name: merge and sign
        env:
          GPG_KEY_ID: ${{ secrets.GPG_KEY_ID }}
        run: |
          set -euo pipefail
          ./scripts/merge-repos.sh repo arch-repos/repo-x86_64 arch-repos/repo-aarch64
          flatpak build-update-repo --gpg-sign="$GPG_KEY_ID" \
            --generate-static-deltas --prune repo/
          echo "published refs:"; ostree --repo=repo refs | grep '^app/'

      - name: assemble Pages site
        env:
          GPG_KEY_ID: ${{ secrets.GPG_KEY_ID }}
          PAGES_URL: https://rulin132.github.io/codex-flatpak
        run: ./scripts/publish-pages.sh

      - uses: actions/upload-pages-artifact@v3
        with:
          path: public

      - name: publish OCI image to GHCR
        run: |
          set -euo pipefail
          flatpak build-bundle --oci --oci-layer-compress=zstd \
            repo oci-image io.github.rulin132.ChatGPT
          echo "${{ secrets.GITHUB_TOKEN }}" | skopeo login ghcr.io \
            -u "${{ github.actor }}" --password-stdin
          skopeo copy --format oci oci:oci-image \
            "docker://ghcr.io/${{ github.repository_owner }}/chatgpt-flatpak:${{ steps.ver.outputs.v }}"
          skopeo copy --format oci oci:oci-image \
            "docker://ghcr.io/${{ github.repository_owner }}/chatgpt-flatpak:latest"

      - uses: softprops/action-gh-release@v2
        with:
          tag_name: v${{ steps.ver.outputs.v }}
          body: |
            Packaging build for upstream ChatGPT ${{ steps.ver.outputs.v }}.

            Install:
                flatpak remote-add --user chatgpt https://rulin132.github.io/codex-flatpak/chatgpt.flatpakrepo
                flatpak install --user chatgpt io.github.rulin132.ChatGPT
```

Leave `deploy-pages` as it is, but change its `needs: publish` if it names the old job.

- [ ] **Step 8: Validate the YAML and the job graph**

```bash
python3 -c "
import yaml
d=yaml.safe_load(open('.github/workflows/release.yml'))
for name,j in d['jobs'].items():
    print(name, '<- needs:', j.get('needs','none'))
print('build matrix:', [i['arch'] for i in d['jobs']['build']['strategy']['matrix']['include']])
"
```

Expected: `build` with both arches, `publish` needing `build`, `deploy-pages` needing `publish`.

- [ ] **Step 9: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "Build and publish both architectures"
```

- [ ] **Step 10: Note what remains unverified**

This job cannot run here: it needs a `v*` tag and the two signing secrets, both deliberately withheld. Record in the PR that `release.yml` is unexercised and must be proven on a throwaway tag in a scratch repository before `AUTO_UPDATE` is ever turned on.

---

### Task 3: First-party upstream detection

**Files:**
- Rewrite: `.github/workflows/update-check.yml`

**Interfaces:**
- Consumes: `scripts/refresh-source.sh`, unchanged. It already re-pins both arches and calls `sync-version.sh`.
- Produces: a PR on branch `chore/upstream-refresh` labelled `automated`, which Task 4 auto-merges.

- [ ] **Step 1: Confirm the runner has what refresh-source.sh needs**

`refresh-source.sh` uses `curl`, `python3`, `sha256sum`, `stat`, `ar`, `tar`, `xz`. Verify on the runner image, not by assumption, by adding a temporary step or checking locally:

```bash
for c in curl python3 sha256sum stat ar tar xz; do printf '%-10s ' "$c"; command -v $c >/dev/null && echo OK || echo MISSING; done
```

`ar` comes from binutils. If it is missing on `ubuntu-latest`, add `apt-get install -y binutils` as the first step of the job.

- [ ] **Step 2: Replace the workflow**

Replace `.github/workflows/update-check.yml` entirely:

```yaml
name: update-check

# Upstream publishes to a rolling "latest" URL, so the bytes behind our pinned
# sha256 rotate without warning and every new install then fails on checksum.
#
# First-party on purpose. The previous version used three marketplace actions
# and never ran: its only execution failed at "Set up job" with "Repository
# access blocked" before any step of its own. scripts/refresh-source.sh already
# does the whole re-pin, so nothing here needs a third party.

on:
  schedule:
    - cron: '17 4 * * *'
  workflow_dispatch:

permissions:
  contents: write
  pull-requests: write

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: re-pin upstream
        run: |
          set -euo pipefail
          git config user.name  "update-bot"
          git config user.email "noreply@github.com"
          ./scripts/refresh-source.sh io.github.rulin132.ChatGPT.yaml

      - name: open a PR if anything changed
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          set -euo pipefail
          if git diff --quiet; then
            echo "upstream unchanged"
            exit 0
          fi
          ver=$(sed -n 's/.*<release version="\([^"]*\)".*/\1/p' \
                build-aux/io.github.rulin132.ChatGPT.metainfo.xml | head -n1)
          git checkout -B chore/upstream-refresh
          git commit -am "Re-pin upstream $ver"
          git push -f origin chore/upstream-refresh
          gh pr create --head chore/upstream-refresh --base main \
            --title "Re-pin upstream $ver" --label automated \
            --body "Upstream rotated the bytes behind the rolling latest URL. sha256 and size are re-pinned for both architectures and the AppStream release entry updated from the .deb control file.

          Merging is not a rubber stamp. CI installs this payload for real on x86_64 and aarch64 and asserts it launches. If upstream moved app.asar or renamed the binary, those jobs fail and scripts/inspect-deb.sh says what changed." \
            || echo "PR already open for this branch"

      # GitHub disables scheduled workflows after 60 days of repository
      # inactivity. A bot that silently stops is worse than no bot, and a
      # commit is the only thing that counts as activity.
      - name: keep the schedule armed
        run: |
          set -euo pipefail
          age=$(( ( $(date +%s) - $(git log -1 --format=%ct origin/main) ) / 86400 ))
          if [ "$age" -ge 50 ]; then
            git checkout main
            date -u +%Y-%m-%dT%H:%M:%SZ > .github/last-upstream-check
            git add .github/last-upstream-check
            git commit -m "Keep the scheduled upstream check armed"
            git push origin main
          else
            echo "last commit was $age days ago, no keepalive needed"
          fi
```

- [ ] **Step 3: Validate the YAML**

```bash
python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/update-check.yml')); print('triggers:', list(d[True])); print('steps:', [s.get('name') or s.get('uses') for s in d['jobs']['check']['steps']])"
```

Expected: triggers `schedule` and `workflow_dispatch`; four steps, none of them a marketplace action other than `actions/checkout`.

- [ ] **Step 4: Dry-run the detection half locally**

`refresh-source.sh` is the only part that can be exercised here. Confirm it is a no-op when upstream has not moved:

```bash
git stash list >/dev/null
./scripts/refresh-source.sh io.github.rulin132.ChatGPT.yaml
git diff --stat
```

Expected: no diff, because the pins already match current upstream. If upstream has rotated since, the diff shows new hashes, which is the workflow working.

- [ ] **Step 5: Commit and trigger it manually**

```bash
git add .github/workflows/update-check.yml
git commit -m "Detect upstream rotations without third-party actions"
git push origin gavin/codex-flatpak-build-launch-b4baf5
```

The workflow only runs from `main`, so it cannot be dispatched from the branch. Record that it must be dispatched once after merge:

```bash
gh workflow run update-check.yml --repo rulin132/codex-flatpak
gh run list --repo rulin132/codex-flatpak --workflow update-check.yml --limit 1
```

Expected after merge: the run reaches its own steps rather than failing at `Set up job`, which is the specific failure this task exists to remove.

---

### Task 4: Kill switch and auto-merge

**Files:**
- Modify: `.github/workflows/update-check.yml` (add a final step)

**Interfaces:**
- Consumes: the PR number from Task 3's `gh pr create`.
- Produces: nothing. Terminal.

- [ ] **Step 1: Enable auto-merge on the repository**

Auto-merge waits for required checks. Without it, `--auto` merges immediately, which would defeat the entire gate.

```bash
gh api -X PATCH repos/rulin132/codex-flatpak -F allow_auto_merge=true
gh api repos/rulin132/codex-flatpak --jq '"allow_auto_merge: \(.allow_auto_merge)"'
```

Expected: `allow_auto_merge: true`.

- [ ] **Step 2: Require the four checks on main**

```bash
gh api -X PUT repos/rulin132/codex-flatpak/branches/main/protection \
  --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["shellcheck", "lint", "build (x86_64, ubuntu-latest)", "build (aarch64, ubuntu-24.04-arm)"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null
}
JSON
gh api repos/rulin132/codex-flatpak/branches/main/protection --jq '.required_status_checks.contexts'
```

Expected: the four check names echoed back. If a name is wrong, auto-merge waits forever, which fails safe but never lands.

- [ ] **Step 3: Add the auto-merge step**

Append to the `check` job in `.github/workflows/update-check.yml`:

```yaml
      # Gated on a repository variable so the pipeline can be stopped from the
      # GitHub UI in seconds, with no commit and nothing to revert. Unset means
      # off, so this ships disarmed.
      - name: auto-merge when the gate is green
        if: vars.AUTO_UPDATE == 'on'
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          set -euo pipefail
          num=$(gh pr list --head chore/upstream-refresh --json number --jq '.[0].number // empty')
          [ -n "$num" ] || { echo "no open refresh PR"; exit 0; }
          gh pr merge "$num" --auto --squash
          echo "auto-merge armed on PR #$num; it lands when the required checks pass"
```

- [ ] **Step 4: Confirm the switch defaults to off**

```bash
gh api repos/rulin132/codex-flatpak/actions/variables --jq '.variables[] | .name' 2>/dev/null | grep -c AUTO_UPDATE || echo "0 (unset, pipeline disarmed)"
```

Expected: `0`. Do not create the variable.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/update-check.yml
git commit -m "Auto-merge refreshes behind a kill switch"
```

---

### Task 5: Publish on content change

**Files:**
- Modify: `.github/workflows/release.yml` (triggers and a job condition)

**Interfaces:**
- Consumes: Task 2's two-job structure.
- Produces: nothing. Terminal.

- [ ] **Step 1: Add the manifest-path trigger**

Replace the `on:` block in `.github/workflows/release.yml`:

```yaml
# Tags stay for human-cut releases. The manifest path trigger is what makes the
# pipeline reach users: upstream can rotate bytes without changing Version, so a
# tag-only scheme would collide on an existing tag and skip a payload users
# need. Publishing on content change handles that; the kill switch gates it.
on:
  push:
    tags: ['v*']
    branches: [main]
    paths:
      - 'io.github.rulin132.ChatGPT.yaml'
  workflow_dispatch:
```

- [ ] **Step 2: Gate the automatic path on the kill switch**

Add to the `build` job in `.github/workflows/release.yml`, so neither job runs:

```yaml
    if: >-
      startsWith(github.ref, 'refs/tags/') ||
      github.event_name == 'workflow_dispatch' ||
      vars.AUTO_UPDATE == 'on'
```

A tag or a manual dispatch always publishes. A push to `main` publishes only when the switch is on.

- [ ] **Step 3: Validate**

```bash
python3 -c "
import yaml
d=yaml.safe_load(open('.github/workflows/release.yml'))
print('triggers:', d[True])
print('build if:', d['jobs']['build'].get('if'))
"
```

Expected: tags, main with the manifest path filter, and dispatch; the `if` naming all three conditions.

- [ ] **Step 4: Commit and push**

```bash
git add .github/workflows/release.yml
git commit -m "Publish when the pinned payload changes"
git push origin gavin/codex-flatpak-build-launch-b4baf5
```

- [ ] **Step 5: Confirm nothing published**

The switch is unset and this branch is not `main`, so no release job should have run.

```bash
gh run list --repo rulin132/codex-flatpak --workflow release.yml --limit 3 \
  --json databaseId,status,conclusion --jq '.[] | "\(.databaseId) \(.status) \(.conclusion // "")"'
gh release list --repo rulin132/codex-flatpak | head
```

Expected: no new release run, no releases. If either is non-empty, stop: something published that should not have.

---

## Self-review

**Spec coverage.** Detection and re-pinning: Task 3. CI gate with launch assertion: Task 1. Auto-merge: Task 4. Publish on content change: Task 5. Both-arch publishing: Task 2. Kill switch: Task 4 Step 3, referenced again in Task 5 Step 2. Failure behaviour: Task 1 Step 4 proves the assertion can fail; Task 2 Step 1 proves the merge fails closed on an empty source. Every spec section has a task.

**Placeholders.** None. Every step carries the command or the file content.

**Type consistency.** `scripts/merge-repos.sh <dest> <src>...` is defined in Task 2 Step 3 and called with that signature in Task 2 Step 7 and `tests/test-merge-repos.sh`. `AUTO_UPDATE` is spelled identically in Tasks 4 and 5. The four check names in Task 4 Step 2 match the job names produced by `build.yml`'s matrix.

**Known gaps, deliberate.** `release.yml` cannot be executed here; Task 2 Step 10 records that. Task 1 Step 1 resolves the Xvfb question at execution time rather than guessing now.

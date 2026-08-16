# Self-updating pipeline

Status: design, approved for spec. Nothing implemented.
Date: 2026-08-16

## Problem

Upstream publishes to a rolling URL with no version in it. When OpenAI rotates
the bytes behind it, the pinned `sha256` stops matching and every new install
fails with "Invalid checksum for extra data". Today that requires a human to
notice, run `make hashes`, review, merge, and publish.

The goal is that a rotation upstream results in updated users, with no human in
the loop, while keeping the packaging honest about what it verified.

## Goals

- Detect a rotation within a day and re-pin both architectures.
- Gate every automatic step on the smoke test that actually installs the payload.
- Reach users unattended: Pages remote and GHCR image both refreshed.
- Reduce third-party dependencies rather than add them.
- Be pausable in seconds without editing or reverting workflows.

## Non-goals

- Deciding the app id or the Pages URL. Both are unresolved and the first
  publish fixes them permanently for anyone who installs.
- Publishing anything before that decision is made.
- Replacing the human review of packaging changes. This automates upstream
  payload refreshes only, not changes to the packaging itself.

## Current state

Verified on 2026-08-16, not assumed.

- `build.yml` is green on all four jobs: shellcheck, manifest lint, and build
  plus install smoke test on x86_64 and aarch64. It triggers on pushes to
  `main`, pull requests and manual dispatch. **Not on tags.**
- `update-check.yml` has run once, on 2026-08-15, and failed at `Set up job`
  with `Repository access blocked` before any of its own steps executed. Actions
  is enabled and the repository is neither archived nor disabled, so the message
  points at one of its three third-party dependencies being unavailable:
  `gautamkrishnar/keepalive-workflow`, `peter-evans/create-pull-request`, or the
  `ghcr.io/flathub/flatpak-external-data-checker` image.
- `release.yml` is a single non-matrix job on `ubuntu-latest`. A repo it builds
  contains one ref, `app/io.github.rulin132.ChatGPT/x86_64/master`. aarch64 is
  pinned in the manifest, built and installed in CI, and advertised in the
  README, but would never be published.
- `scripts/refresh-source.sh` already does the whole re-pin: both arches,
  `sha256` and `size` into the manifest, `Version:` out of the control archive,
  and `sync-version.sh` for the AppStream entry.

## Design

### 1. Detection and re-pinning

Replace `update-check.yml`'s three third-party dependencies with first-party
equivalents. The work is already done and tested:

- The external data checker becomes `scripts/refresh-source.sh`.
- `peter-evans/create-pull-request` becomes `gh pr create`.
- `gautamkrishnar/keepalive-workflow` becomes a few lines: if the run finds
  nothing to do and the newest commit is older than 50 days, commit a timestamp
  file. GitHub disables scheduled workflows after 60 days of repository
  inactivity, and a bot that silently stops is worse than no bot.

Nightly cron plus manual dispatch. If the manifest is unchanged after the
refresh, exit quietly. If it changed, push a branch and open a PR labelled
`automated`.

### 2. CI gate

`build.yml` gains a launch assertion: install the payload, run the app headless,
require the `window ready-to-show` line. This raises the bar from "the payload
unpacks and contains an ELF" to "the payload runs".

This is the only part with real technical risk. zypak spawns renderers through
the Flatpak portal over D-Bus, and a CI container has no session bus. zypak
ships a mimic strategy for that case, but it is unproven here. See Risks.

### 3. Auto-merge

A job on the bot's PR runs `gh pr merge --auto --squash`, gated on the kill
switch. Auto-merge waits for required checks, so the four jobs must be marked
required in branch protection and "Allow auto-merge" must be enabled. Without
both, auto-merge has nothing to wait on and would merge immediately.

Only PRs opened by the bot, identified by the `automated` label and the branch
name, are eligible. A human PR never auto-merges.

### 4. Publish on content change

Restore the `push: branches: [main]` trigger on `release.yml`, path-filtered to
the manifest, gated on the kill switch.

This reverses a change made on 2026-08-15, which restricted releases to `v*`
tags. That was correct at the time, because the smoke test did not run at all
and nothing stood between a push and a publish. It is acceptable now only
because that gate exists and is green on both architectures.

Publishing on content change rather than on a tag also handles an edge case that
tags cannot. Upstream can rotate bytes without changing `Version:`, a rebuild of
the same release. Tag-based publishing would collide with the existing tag and
skip a payload that users need.

The `v*` tag trigger stays for human-cut releases, along with the check that a
pushed tag matches the manifest version.

### 5. Prerequisite: publish both architectures

`release.yml` becomes two jobs:

- `build`: a matrix over x86_64 and aarch64, each on its native runner, each
  running the same install and smoke assertions as `build.yml`, each uploading
  its signed repo as an artifact.
- `publish`: downloads both, merges them into one repo, signs and generates
  static deltas once, then assembles Pages and pushes the OCI image.

Nothing else in this design is safe until this lands, because the automation
would otherwise reliably ship an x86_64-only remote.

## Kill switch

A repository variable, `AUTO_UPDATE`, read by the auto-merge job and the publish
job. Anything other than `on` stops both. It defaults to unset, so the pipeline
ships disarmed and stays that way until the app id is settled.

Chosen over a workflow edit because it can be flipped from the GitHub UI in
seconds, needs no commit, and cannot be forgotten in a branch.

## Data flow

```
OpenAI rotates the payload
  -> nightly job: refresh-source.sh re-pins both arches, syncs the version
  -> no change?  exit, keepalive if the repo has been quiet 50 days
  -> changed?    branch + gh pr create (labelled automated)
  -> build.yml:  shellcheck, lint, build + install + launch, x86_64 and aarch64
  -> any red?    PR stays open, nothing publishes, a human looks
  -> all green + AUTO_UPDATE=on?  auto-merge
  -> merge to main touching the manifest + AUTO_UPDATE=on
  -> release.yml: matrix build both arches, merge repos, sign
  -> Pages remote + GHCR image refreshed
  -> users get it on their next flatpak update
```

## Failure behaviour

Every stage fails closed, which is the existing posture of `apply_extra` and
should stay the posture of the pipeline around it.

- Upstream unreachable or a partial download: `fetch-deb.sh` leaves the cache
  untouched and exits non-zero. No PR.
- Layout changed: `apply_extra` aborts with a specific message, the smoke test
  fails, the PR does not merge, nothing publishes. This is the case the whole
  design exists to catch.
- Launch assertion fails: same, treated as a failed smoke test.
- One architecture fails: `fail-fast: false` lets the other finish so the logs
  show whether it is arch-specific, but the merge is still blocked.
- Kill switch off: PR is opened and CI runs as normal. Only merge and publish
  stop, so detection keeps working and a human sees the PR.

## Testing

- `refresh-source.sh` and `sync-version.sh` behaviour is covered by
  `tests/test-sync-version.sh`, which runs in CI.
- The launch assertion is proven or disproven by a spike before anything is
  built on it, run against a real payload in a container without a session bus.
- The `release.yml` rewrite is exercised on a throwaway tag in a scratch
  repository before it is trusted, because it cannot be tested here without
  cutting a real tag and setting the signing secrets.
- The end-to-end path is verified once with `AUTO_UPDATE` on and a deliberately
  stale pin, to confirm the chain runs and publishes, before it is left
  unattended.

## Risks and open questions

**The launch assertion may not work headless.** zypak needs the Flatpak Spawn
portal over D-Bus. If the mimic fallback does not work in a container, the
options are to drop the assertion and keep the existing payload assertions, or
run it under a session bus started in the job. Resolve by spike first.

**The app id is unresolved and the first publish is irreversible.** Automation
does not change that, it changes who makes the decision and when: a cron job, on
whatever night upstream rotates. The kill switch defaulting to off is what keeps
this safe, and it must not be turned on before the id is final.

**Auto-merge overrides the project's human merge gate.** Accepted deliberately
by the maintainer on 2026-08-16 for bot-authored payload refreshes only.

**Unattended publishing means an upstream regression that still passes the smoke
test reaches users.** A soak delay was considered and rejected in favour of the
launch assertion plus the kill switch.

## Sequencing

1. Spike the headless launch. It can invalidate part 2.
2. Rewrite `release.yml` for both architectures. Prerequisite for anything else.
3. Rewrite `update-check.yml` first-party.
4. Add the auto-merge job and the kill switch.
5. Restore publish on content change.
6. Leave `AUTO_UPDATE` unset until the app id is decided.

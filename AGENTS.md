# burrowee-release

Public, signed self-service install channel for the Burrowee platform
(`release.burrowee.com`). Publishes signed installers + binaries for four
components — `cli`, `gateway`, `edge`, `agent` (relay is private/gated and
not served here) — each verified end-to-end by the outer bootstrap: minisign
signature check → SHA-256 check → unzip → exec the verified inner installer.

- `burrowee-git/release` (PUBLIC). Trunk: `main`, PR-only — there is no
  `dev` worktree; feature work branches straight from `main` into its own
  `code/.worktrees/<branch>`. gh.account: `burrowee-git`.
- Stack: Go 1.25 (module `github.com/burrowee-git/release`). Consumes
  `github.com/burrowee-git/release-kit` (pinned `v0.1.1` in `go.mod`) for
  the build/sign/checksum primitives, plus shell scripts under `tools/`.

## Scope of this manual

This describes what's **in** the repo and how to work on its Go code and
scripts. It does **not** cover cutting, signing, promoting, or shipping a
release — that's operator-run tooling (`tools/release.sh` and the other
`tools/*.sh` scripts) and out of scope for a contributor. Reading this
manual should not leave you thinking you should run a release.

## Layout

```
cmd/relay-gate/                 relay registration gate service
cmd/rkit/                       release-kit-based build CLI (wraps release-kit primitives)
cmd/burrowee-release-register/  registers a cut release with the console/catalog
internal/register/              publish/prune/keygen/r2 logic for burrowee-release-register
internal/gate/                  relay-gate server: fingerprinting, nonce, rate-limit, registry
internal/relconfig/             per-component release config + version stamping
internal/r2/                    R2 (S3-compatible) client + request signer
inner/<comp>/*.template.sh      the AUTHORED inner installers — edit these
inner/<comp>/install.sh         inner installer shipped inside each component's signed zip
                                 (generated; beta.install.sh beside it is its twin)
cli/ gateway/ edge/ agent/      per-component outer bootstrap (install.sh, generated;
                                 beta.install.sh etc. while a cycle is open)
relay/install.sh                relay's (gated, non-public) install path
config/console-pub.hex          console signing pubkey baked into edge builds
site/index.html                 release.burrowee.com landing page
skills/<name>/SKILL.md          12 self-contained AI-agent skills (burrowee,
                                 burrowee-account, burrowee-cli-install,
                                 burrowee-cli-setup, burrowee-connect,
                                 burrowee-domains, burrowee-edge-install,
                                 burrowee-edge-setup, burrowee-gateway-install,
                                 burrowee-gateway-setup, burrowee-remote-access,
                                 burrowee-sessions) — each served at
                                 release.burrowee.com/skills/<name>/SKILL.md and
                                 linked from the ai repo's skill index
versions/                       per-component SemVer source of truth
tools/                          build/version/bootstrap-generation scripts + the
                                 operator-run release.sh orchestrator (see Scope above);
                                 apple_sign.sh + vulncheck.sh hold release.sh's
                                 testable predicates, each with a *.test.sh beside it;
                                 RUNBOOK.md = operator notes on hazards the tooling
                                 does not prevent
ops/                            nginx/systemd unit files for the hosting side (reference only)
```

## Channels — a beta install sits BESIDE the stable one (2026-09-04)

The ruling this replaces (2026-09-01, beta-only cuts while the 0.3 cycle is
open) existed because there was one installer and one root: `inner/<comp>/install.sh`
targeted `/usr/local/burrowee/{bin,etc,var}` unconditionally, so installing a
beta build meant installing OVER the stable one, and a stable cut from `main`
would have shipped that installer under 0.2 binaries. Neither is true any more.

The installers are now rendered per channel from three constants —
`tools/channels.sh`: the install root, the dispatcher name, and the channel
segment in the unit names. A beta install goes to `/usr/local/burrowee/beta`,
carries the `burroweeb` dispatcher, and runs as `burrowee-beta-<comp>` /
`com.burrowee.beta.<comp>`. **Beta twins install beside stable, never over it,
and a beta cut is allowed for every component that ships a twin.** So is a
stable cut: nothing about an open beta cycle blocks one.

Two things to know before editing anything under `inner/` or `tools/*.template.sh`:

- **The generated files are committed, and the stable render must not move.**
  `tools/gen-bootstraps.sh` writes both channels of the outer bootstraps and
  the inner installers; `tools/test-bootstraps.sh` fails while the tree and
  the generator disagree, and its first assertion is that every stable
  artefact came back byte-identical. Edit the `*.template.sh`, re-run the
  generator, commit both.
- **A channel difference is a render-time substitution or a dropped block**,
  never a runtime branch — `@ROOT@` / `@DISPATCHER@` / `@UNIT_PREFIX@`, or an
  `@STABLE_ONLY_BEGIN@` / `@BETA_ONLY_BEGIN@` block. A runtime branch would
  move the literal and make every stable installer in the world a new file.

The former ruling's expected-red note stands on its own terms:
`tools/install-waits-for-daemon.test.sh` reads the daemons from the sibling
`*/code/main` checkouts, which are 0.2, and goes green by itself when 0.3
graduates to `main`.

## Core principles

See [`DEVELOPMENT.md`](https://github.com/burrowee-git/resources/blob/main/docs/guidelines/DEVELOPMENT.md)
for the standard this code is written and reviewed against: think before
coding, simplicity first, surgical changes, verify before declaring done.

## Task dispatch

Coding, testing, and review work in this repo runs as subagent tasks —
point the subagent at the Guidelines table below.

## Guidelines

Canonical, shared across all Burrowee repos — read from `burrowee-git/resources`:

| Task | File |
|---|---|
| Contributing: branch → PR → review | [`docs/guidelines/WORKFLOW.md`](https://github.com/burrowee-git/resources/blob/main/docs/guidelines/WORKFLOW.md) |
| Principles · naming · architecture · errors · tests | [`docs/guidelines/DEVELOPMENT.md`](https://github.com/burrowee-git/resources/blob/main/docs/guidelines/DEVELOPMENT.md) |
| Code review compliance | [`docs/guidelines/CODE-REVIEW.md`](https://github.com/burrowee-git/resources/blob/main/docs/guidelines/CODE-REVIEW.md) |
| Traps that will bite you | [`docs/guidelines/TRAPS.md`](https://github.com/burrowee-git/resources/blob/main/docs/guidelines/TRAPS.md) |
| New here? | [`docs/onboarding/`](https://github.com/burrowee-git/resources/blob/main/docs/onboarding/README.md) |

Operator-only (machine-local, not required to contribute): release signing, deploy,
and the local repo registry live outside these repos and are not needed to write code
here.

## Tasks

Open follow-ups: `tasks/2026-09-02/P1-v0-3-crossing-followups-gateway-relay-4h.md` — the
gateway and relay halves of the 0.2→0.3 crossing, which must land before a 0.3 beta build
reaches an existing 0.2 host.

Deferred work for this repo lives at [`../../tasks/`](../../tasks/) (project
root, beside `code/` — outside the working tree). One file per task, grouped by
creation date: `tasks/{YYYY-MM-DD}/{priority}-{slug}-{hours}h.md`. `ls P*` shows
open work; `completed.*` / `dropped.*` are renamed in place.

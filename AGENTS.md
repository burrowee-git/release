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
inner/<comp>/install.sh         inner installer shipped inside each component's signed zip
cli/ gateway/ edge/ agent/      per-component outer bootstrap (install.sh, generated)
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

## Channel ruling — beta-only cuts while the 0.3 cycle is open (2026-09-01)

The inner installers (`inner/gateway/install.sh`, `inner/edge/install.sh`, the two
`updater.install.sh`) target the **0.3** system root, `/usr/local/burrowee/{etc,var,bin}`,
and this repo has no per-channel installer: a stable cut from `main` would ship them under
0.2 binaries whose daemons still write `/usr/local/var/burrowee/<comp>`. The operator's
ruling: **only `beta` cuts are made until 0.3 graduates. No stable cut of gateway or edge
unless the operator explicitly starts a stable-cut session** — and that session first
resolves the installer split (the candidate design is relay's: the installer travels with
the component source, so rkit picks it from the tree it is building).

Consequence to expect and not "fix": `tools/install-waits-for-daemon.test.sh` is **red**
while this ruling stands. It reads the daemons from the sibling `*/code/main` checkouts,
which are 0.2 — the mismatch it reports is the exact hazard the ruling guards against, and
it goes green by itself when 0.3 graduates to `main`. Every other suite is green or
name-identical to `main`'s container baseline.

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

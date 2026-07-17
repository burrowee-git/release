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
versions/                       per-component SemVer source of truth
tools/                          build/version/bootstrap-generation scripts + the
                                 operator-run release.sh orchestrator (see Scope above)
ops/                            nginx/systemd unit files for the hosting side (reference only)
```

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

# Burrowee release channel

Public, signed, self-service install channel for the Burrowee platform. Each
component ships the `burrowee` universal dispatcher plus its own binaries, and
every download is verified end-to-end (minisign signature → SHA-256 → unzip →
exec a verified inner installer).

Three components are published here:

| Component | Binaries | What it is |
|---|---|---|
| `cli` | `burrowee`, `burrowee-cli` | client CLI — connect, ssh, pair, relays |
| `gateway` | `burrowee`, `burrowee-gateway`, `burrowee-register` | gateway daemon + registration tool |
| `edge` | `burrowee`, `burrowee-edge` | self-hosted relay |

## Install

```sh
# CLI
curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/cli/install.sh | sh
# Gateway
curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/gateway/install.sh | sh
# Edge relay
curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/edge/install.sh | sh
```

Each installer detects your OS/arch, resolves the latest published release for
that component, downloads the zip + `SHA256SUMS.txt` + `SHA256SUMS.txt.minisig`,
**verifies the minisign signature against the baked public key**, checks the
SHA-256, then unzips and runs the inner installer. Binaries land in
`$HOME/.local/bin` (override with `PREFIX`).

## Verify by hand

The signing public key lives in this repo and is mirrored at
`https://release.burrowee.com/burrowee-release.pub`. To verify a download
yourself:

```sh
minisign -V -P "$(cat burrowee-release.pub)" \
  -m SHA256SUMS.txt -x SHA256SUMS.txt.minisig
shasum -a 256 -c --ignore-missing SHA256SUMS.txt   # or sha256sum on Linux
```

A failed signature check means the bytes are untrusted — do not install them.

## Pin a version

Each component reads a version-pin env var. The value is the release tag
(`<comp>/<stamp>`):

| Component | Env var |
|---|---|
| `cli` | `BURROWEE_CLI_VERSION` |
| `gateway` | `BURROWEE_GATEWAY_VERSION` |
| `edge` | `BURROWEE_EDGE_VERSION` |

```sh
BURROWEE_CLI_VERSION=cli/v0.1.0.2026.06.08.7dbdd72 \
  curl -fsSL https://release.burrowee.com/cli/install.sh | sh
```

Unset → the installer resolves the newest release for that component.

## Supported platforms

| OS | arm64 | amd64 |
|---|---|---|
| macOS (darwin) | ✓ | ✓ |
| Linux | ✓ | ✓ |

Windows is not supported.

## For LLM coding agents

Skill packages for fresh-context agents are mirrored under
`https://release.burrowee.com/skills/`:

- `burrowee-cli-install` / `burrowee-cli-setup`
- `burrowee-gateway-install` / `burrowee-gateway-setup`
- `burrowee-edge-install` / `burrowee-edge-setup`

## How this repo is built

This is the public face of the channel. Built binaries for the private
component repos are published as **GitHub Release assets on this repo** (the
component sources are private and can't be `curl`'d anonymously). The static
bootstrap scripts and skills are mirrored to `release.burrowee.com`
(nginx + Cloudflare).

```
cli/  gateway/  edge/      ← per-component outer bootstrap (install.sh, generated)
inner/<comp>/install.sh    ← inner installer (ships inside each verified zip)
versions/<comp>            ← per-component SemVer source of truth
config/cloud-pub.hex       ← live cloud signing pubkey, baked into edge builds
skills/                    ← *-install / *-setup SKILL.md packages
site/index.html            ← release.burrowee.com landing page
tools/                     ← version.sh, build.sh, gen-bootstraps.sh, release.sh
burrowee-release.pub       ← minisign signing public key (added at activation)
```

- `burrowee-git/release` (PUBLIC). Trunk: `main`. gh.account: `burrowee-git`.
- Call gh via `~/.claude/bin/ghp`, never bare `gh`.

## Status

Preview release. Expect rough edges; report issues on this repo.

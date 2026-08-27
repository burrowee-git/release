# Burrowee release channel

Public, signed, self-service install channel for the Burrowee platform. Each
component ships the `burrowee` universal dispatcher plus its own binaries, and
every download is verified end-to-end (minisign signature → SHA-256 → unzip →
exec a verified inner installer).

Four components are published here:

| Component | Binaries | What it is |
|---|---|---|
| `cli` | `burrowee`, `burrowee-cli`, `burrowee-cli-updater` | client CLI — connect, ssh, pair, relays |
| `gateway` | `burrowee`, `burrowee-gateway`, `burrowee-gateway-cli`, `burrowee-gateway-console`, `burrowee-register`, `burrowee-gateway-updater` | gateway daemon + registration tool |
| `edge` | `burrowee`, `burrowee-edge`, `burrowee-edge-cli`, `burrowee-edge-updater` | self-hosted relay |
| `agent` | `burrowee`, `burrowee-agent` | AI-agent identity client — key-signed control-plane access |

## Install

```sh
# CLI
curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/cli/install.sh | sh
# Gateway
curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/gateway/install.sh | sh
# Edge relay  (root-only: manages a system service)
curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/edge/install.sh | sudo sh
# Agent
curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/agent/install.sh | sh
```

Each installer detects your OS/arch, resolves the latest published release for
that component, downloads the zip + `SHA256SUMS.txt` + `SHA256SUMS.txt.minisig`,
**verifies the minisign signature against the baked public key**, checks the
SHA-256, then unzips and runs the inner installer.
If `minisign` is missing, the installer provides it first — through your package
manager where the installer has root (or, for a user-level install, passwordless
sudo), otherwise the official upstream 0.12 build whose SHA-256 is pinned inside
the installer itself and whose own signature is then checked against upstream's
key — and refuses to continue if neither works; it never runs an unverified
verifier.
An uninstall never touches your package manager; if it had to fetch the pinned
build to verify its payload, that single `minisign` file stays in the bin
directory afterwards.
Binaries land in
`$HOME/.local/bin` (override with `PREFIX`) — **except the gateway and the
edge**, which install to the root-owned `/usr/local/bin` and nowhere else:
their service units run as root and name the binaries absolutely, and other
components resolve `/usr/local/bin/burrowee` by absolute path. A `PREFIX` set
for either is refused rather than honoured or silently overridden. The edge
additionally requires root — it manages a system service, so run it with
`sudo` (as the one-liner above does).

## Verify by hand

The signing public key lives in this repo and is mirrored at
`https://release.burrowee.com/burrowee-release.pub`. To verify a download
yourself:

```sh
minisign -V -P "$(cat burrowee-release.pub | tail -n1)" \
  -m SHA256SUMS.txt -x SHA256SUMS.txt.minisig
f=<file>                                      # the file you downloaded
want=$(awk -v f="$f" '{ n = $2; sub(/^\*/, "", n); if (n == f) { print $1; exit } }' SHA256SUMS.txt)
got=$(shasum -a 256 "$f" | awk '{print $1}')  # sha256sum "$f" on Linux
if   [ -z "$want" ];        then echo "NO ENTRY for $f in SHA256SUMS.txt — do not install"
elif [ "$want" = "$got" ];  then echo "OK $f"
else                             echo "MISMATCH for $f — do not install"; fi
```

A failed signature check means the bytes are untrusted — do not install them.

The checksum block compares one digest by hand on purpose. `shasum -c
--ignore-missing` is what the installers used to run, and the stock `shasum` on
a pre-2016 macOS rejects that option outright — which read as "tampered". Its
obvious replacement is worse: `sha256sum -c` exits **0** on an empty or
malformed checklist, so a mistyped filename would report success having verified
nothing. Selecting the entry by exact name and shouting when there is none is
what the installer's own gate does.

## Pin a version

Each component reads a version-pin env var. The value is the release tag
(`<comp>/<stamp>`):

| Component | Env var |
|---|---|
| `cli` | `BURROWEE_CLI_VERSION` |
| `gateway` | `BURROWEE_GATEWAY_VERSION` |
| `edge` | `BURROWEE_EDGE_VERSION` |
| `agent` | `BURROWEE_AGENT_VERSION` |

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

- `burrowee` (entry point)
- `burrowee-cli-install` / `burrowee-cli-setup`
- `burrowee-gateway-install` / `burrowee-gateway-setup`
- `burrowee-edge-install` / `burrowee-edge-setup`
- `burrowee-account`, `burrowee-connect`, `burrowee-domains`, `burrowee-remote-access`, `burrowee-sessions`

## How this repo is built

This is the public face of the channel. Built binaries for the private
component repos are published as **GitHub Release assets on this repo** (the
component sources are private and can't be `curl`'d anonymously). The static
bootstrap scripts and skills are mirrored to `release.burrowee.com`
(nginx + Cloudflare).

```
cli/  gateway/  edge/  agent/  ← per-component outer bootstrap (install.sh, generated)
inner/<comp>/install.sh    ← inner installer (ships inside each verified zip)
versions/<comp>            ← per-component SemVer source of truth
config/console-pub.hex     ← live console signing pubkey, baked into edge builds
skills/                    ← *-install / *-setup SKILL.md packages
site/index.html            ← release.burrowee.com landing page
tools/                     ← version.sh, build.sh, gen-bootstraps.sh, release.sh
tools/RUNBOOK.md           ← operator notes on hazards the tooling does not prevent
burrowee-release.pub       ← minisign signing public key (added at activation)
```

- `burrowee-git/release` (PUBLIC). Trunk: `main`. gh.account: `burrowee-git`.
- Call gh via `~/bin/ghp`, never bare `gh`.

## Status

Preview release. Expect rough edges; report issues on this repo.

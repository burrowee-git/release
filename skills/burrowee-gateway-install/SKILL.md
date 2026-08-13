---
name: burrowee-gateway-install
description: Install the burrowee gateway (home-NAT tunnel endpoint) on this machine (macOS + Linux). Use when the operator asks to "install burrowee gateway", "get the gateway binary", or pastes release.burrowee.com/gateway/install.sh or release.burrowee.com/skills/burrowee-gateway-install/SKILL.md. Stop after the binaries are on PATH and `burrowee gateway version` reports a version — configuration + run live in the burrowee-gateway-setup skill, which the operator triggers next.
---

# burrowee-gateway-install

You are an LLM coding agent (Claude Code, Cursor, Aider, …) tasked with putting the
**burrowee gateway** on this machine. The install drops three binaries into PATH:
the `burrowee` dispatcher, the `burrowee-gateway` component, and the
`burrowee-register` registrar helper. The dispatcher execs the components, so
`burrowee gateway …` / `burrowee register …` and the bare `burrowee-gateway …` /
`burrowee-register …` are the same surface.

The job is narrow: install + verify. Do **not** configure or start the gateway —
that belongs to the `burrowee-gateway-setup` skill the operator invokes next.

The operator may need out-of-terminal actions (granting shell permissions, opening
a new shell to pick up `PATH`). Pause and ask; resume on confirmation.

---

## 0. Pre-flight

Run these checks; stop and surface the failure if any one fails.

```bash
uname -s            # expected: Darwin (macOS) or Linux
uname -m            # expected: arm64 / aarch64 / x86_64 / amd64
command -v curl
command -v sh
command -v unzip
```

Supported platforms: `darwin × {arm64, amd64}`, `linux × {arm64, amd64}`. For
anything else (Windows, BSD, esoteric arch), stop — the bootstrap rejects
unsupported OS/arch and there is no official build. (A gateway is most often run on
a Linux box behind home NAT.)

If `unzip` is missing, install it (`brew install unzip` on macOS; `sudo apt
install unzip` on Debian/Ubuntu; `sudo dnf install unzip` on RHEL/Fedora) and
retry the pre-flight.

Already installed? If `burrowee gateway version` already prints a version line, the
gateway is present — route the operator straight to `burrowee-gateway-setup` and
stop.

---

## 1. Install

```bash
curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/gateway/install.sh | sh
```

This bootstrap is the trust anchor: it downloads the platform-matched release zip
plus `SHA256SUMS.txt` and its minisign signature, verifies the signature against a
baked-in public key, verifies the zip's sha256 against the now-trusted sums, and
ONLY THEN unzips and runs the inner installer. The inner installer copies
`burrowee` + `burrowee-gateway` + `burrowee-register` into `/usr/local/bin`,
root-owned — since 0.2.0 that is the gateway's only destination, and the
installer elevates via `sudo` to place them (it prompts on the terminal, or
needs cached `sudo` credentials when run non-interactively). The gateway's
service units run as root and name these paths absolutely, and other components
resolve `/usr/local/bin/burrowee` by absolute path, so a per-user copy would be
invisible to both: setting `PREFIX` does not move the install, it is **refused**
with a non-zero exit and nothing is written. On macOS the installer clears the
quarantine xattr on each binary.

If the bootstrap fails before install (signature/sha mismatch, download error), it
aborts without writing anything — surface the raw output and stop.

---

## 2. Verify

```bash
# Preferred:
burrowee gateway version

# Fallback by full path:
/usr/local/bin/burrowee gateway version
```

`burrowee gateway version` prints `burrowee-gateway <version>`. That is the real,
source-backed version command for the component. **STOP here once a real version
line prints.**

> The unified `burrowee gateway version` and the bare `burrowee-gateway version`
> are equivalent — the dispatcher just execs the gateway component. Apart from
> `version`, `burrowee-gateway` is configured entirely by environment variables
> (covered in `burrowee-gateway-setup`) and starts running when invoked with no
> subcommand, and `burrowee-register` takes `-sock`/`-name`/`-target` flags. Do not
> run a bare `burrowee gateway` here (it would try to start with missing env).

`/usr/local/bin` is on the default PATH of every supported shell, so no rc edit
is needed and the installer makes none. If `burrowee` is still not found there,
the install did not land — do not work around it with a PATH edit.

Anything else (missing binary, "command not found" even by full path, wrong-arch
error) means the install didn't land — surface the output and stop.

---

## 3. Hand back

Once `burrowee gateway version` succeeds, **stop**. Tell the operator:

> burrowee gateway is installed at `/usr/local/bin` (`burrowee` +
> `burrowee-gateway` + `burrowee-register`). To configure its keys/PSK/relay and
> bring it up, run the **burrowee-gateway-setup** skill next (or paste
> `https://release.burrowee.com/skills/burrowee-gateway-setup/SKILL.md` into your
> coding agent).

Do not run `burrowee gateway` from this skill — it expects required environment
(relay URL, key path, PSK path) the setup flow gathers.

---

## Troubleshooting

- **"unsupported arch" on a known-good Apple Silicon Mac.** A Rosetta-emulated
  shell reports `x86_64`; close any Rosetta'd terminal and re-run from a native one.
- **`Failed to connect to release.burrowee.com`.** The artifact host is on
  Cloudflare; corporate proxies sometimes block. Check
  `curl -v https://release.burrowee.com/gateway/install.sh` and surface the TLS/HTTP
  error.
- **(macOS) Gatekeeper blocks a binary.** The inner installer already strips
  `com.apple.quarantine`; if a copy was moved by hand, clear it manually:
  `sudo xattr -d com.apple.quarantine /usr/local/bin/burrowee /usr/local/bin/burrowee-gateway /usr/local/bin/burrowee-register`.
- **Pin a specific version.** Re-run with `BURROWEE_GATEWAY_VERSION` set to a
  release tag:
  ```bash
  BURROWEE_GATEWAY_VERSION=gateway/v0.1.0.<stamp> \
    sh -c "$(curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/gateway/install.sh)"
  ```
- **Install somewhere else.** Not supported, and not silently ignored: the
  gateway installs to `/usr/local/bin` and a set `PREFIX` aborts the install
  with a message saying so. If `PREFIX` is exported in the operator's shell
  profile for other tools, unset it for this command.
- **Uninstall.** Pass `BURROWEE_UNINSTALL=1` through the bootstrap; it removes
  `burrowee` + `burrowee-gateway` + `burrowee-register` from `/usr/local/bin`:
  ```bash
  BURROWEE_UNINSTALL=1 \
    sh -c "$(curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/gateway/install.sh)"
  ```

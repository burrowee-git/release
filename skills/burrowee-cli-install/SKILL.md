---
name: burrowee-cli-install
description: Install the burrowee cli (the local client + forwarder) on this machine (macOS + Linux). Use when the operator asks to "install burrowee cli", "get the burrowee client", or pastes release.burrowee.com/cli/install.sh or release.burrowee.com/skills/burrowee-cli-install/SKILL.md. Stop after the dispatcher is on PATH and reports its version — pairing + connect live in the burrowee-cli-setup skill, which the operator triggers next.
---

# burrowee-cli-install

You are an LLM coding agent (Claude Code, Cursor, Aider, …) tasked with putting the
**burrowee cli** on this machine. The install drops two binaries into PATH: the
`burrowee` dispatcher and the `burrowee-cli` component. The dispatcher execs the
component, so `burrowee cli …` and the bare `burrowee-cli …` are the same surface.

The job is narrow: install + verify. Do **not** start pairing or connect flows —
those belong to the `burrowee-cli-setup` skill the operator invokes next.

The operator may need to perform out-of-terminal actions (granting shell
permissions, opening a new shell to pick up `PATH`). Pause and ask; resume when
they confirm.

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
unsupported OS/arch and there is no official build.

If `unzip` is missing, install it (`brew install unzip` on macOS; `sudo apt
install unzip` on Debian/Ubuntu; `sudo dnf install unzip` on RHEL/Fedora) and
retry the pre-flight.

Already installed? If `burrowee --version` already prints a version line, the
dispatcher is present — route the operator straight to `burrowee-cli-setup` and
stop.

---

## 1. Install

```bash
curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/cli/install.sh | sh
```

This bootstrap is the trust anchor: it downloads the platform-matched release zip
plus `SHA256SUMS.txt` and its minisign signature, verifies the signature against a
baked-in public key, verifies the zip's sha256 against the now-trusted sums, and
ONLY THEN unzips and runs the inner installer. The inner installer copies
`burrowee` + `burrowee-cli` into `$HOME/.local/bin` (override with `PREFIX`). On
macOS it clears the quarantine xattr on each binary.

If the bootstrap fails before install (signature/sha mismatch, download error), it
aborts without writing anything — surface the raw output and stop.

---

## 2. Verify

```bash
# Preferred:
burrowee --version

# Fallback if PATH isn't refreshed yet:
"$HOME/.local/bin/burrowee" --version
```

`burrowee --version` prints `burrowee dispatcher <version>`. That is the real,
source-backed version command. **STOP here once a real version line prints.**

> There is **no** per-component `version` subcommand. `burrowee cli …` and
> `burrowee-cli …` dispatch to the cli, whose subcommands are `connect`, `ssh`,
> `pair`, `daemon`, `relays` (covered in `burrowee-cli-setup`) — running them with
> no/invalid arguments prints a usage line. Use `burrowee --version` to confirm the
> install landed.

If the bin dir isn't on PATH, tell the operator to add this to their shell rc
(`~/.zshrc`, `~/.bashrc`, …) and open a new shell:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Anything else (missing binary, "command not found" even by full path, wrong-arch
error) means the install didn't land — surface the output and stop.

---

## 3. Hand back

Once `burrowee --version` succeeds, **stop**. Tell the operator:

> burrowee cli is installed at `$HOME/.local/bin` (`burrowee` + `burrowee-cli`). To
> pair against a gateway and open your first connection, run the
> **burrowee-cli-setup** skill next (or paste
> `https://release.burrowee.com/skills/burrowee-cli-setup/SKILL.md` into your
> coding agent).

Do not start `burrowee cli pair`, `connect`, or `daemon` from this skill — the
setup flow needs operator inputs (the pairing blob/PIN/salt from the dashboard,
relay URL, target gateway) that this skill is not equipped to gather.

---

## Troubleshooting

- **"unsupported arch" on a known-good Apple Silicon Mac.** A Rosetta-emulated
  shell reports `x86_64`; close any Rosetta'd terminal and re-run from a native one.
- **`Failed to connect to release.burrowee.com`.** The artifact host is on
  Cloudflare; corporate proxies sometimes block. Check
  `curl -v https://release.burrowee.com/cli/install.sh` and surface the TLS/HTTP
  error.
- **(macOS) Gatekeeper blocks a binary.** The inner installer already strips
  `com.apple.quarantine`; if a copy was moved by hand, clear it manually:
  `xattr -d com.apple.quarantine "$HOME/.local/bin/burrowee" "$HOME/.local/bin/burrowee-cli"`.
- **Pin a specific version.** Re-run with `BURROWEE_CLI_VERSION` set to a release
  tag:
  ```bash
  BURROWEE_CLI_VERSION=cli/v0.1.0.<stamp> \
    sh -c "$(curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/cli/install.sh)"
  ```
- **Install to a different prefix.** Set `PREFIX` (bins land at `PREFIX/bin`):
  ```bash
  PREFIX="$HOME/.burrowee-tools" \
    sh -c "$(curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/cli/install.sh)"
  ```
- **Uninstall.** Pass `BURROWEE_UNINSTALL=1` through the bootstrap; it removes
  `burrowee` + `burrowee-cli` from `PREFIX/bin`:
  ```bash
  BURROWEE_UNINSTALL=1 \
    sh -c "$(curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/cli/install.sh)"
  ```

---
name: burrowee-gateway-install
description: Install the burrowee gateway (home-NAT tunnel endpoint) on this machine (macOS + Linux). Use when the operator asks to "install burrowee gateway", "get the gateway binary", or pastes release.burrowee.com/gateway/install.sh or release.burrowee.com/skills/burrowee-gateway-install/SKILL.md. Stop after the binaries are installed and `burrowee gateway version` reports a version — configuration + run live in the burrowee-gateway-setup skill, which the operator triggers next.
---

# burrowee-gateway-install

You are an LLM coding agent (Claude Code, Cursor, Aider, …) tasked with putting the
**burrowee gateway** on this machine. The binaries live in
`/usr/local/burrowee/bin`, **which is not on PATH**, so the last thing the
installer prints is the `export PATH=…` line for the operator's own login
shell, plus the profile file that makes it permanent. Nothing is written to
that profile for them — they run the line. Until they do, reach every command
by its full path under `/usr/local/burrowee/bin`, and reach the registrar as
`burrowee register …` through the dispatcher rather than by its bare name.

> **Version note.** Releases up to and including the early 0.3 betas ALSO
> symlinked the operator-typed names into `/usr/local/bin` when that directory
> proved root-secure, which is why an older host may have them. This project's
> installer features delete the conditional `/usr/local/bin` symlink step, one
> repo at a time; once they land, installs from the 0.3.x line onward carry no
> such link at all. On a clean modern Mac `/usr/local/bin` does not exist, so
> the link was never made there in the first place — that is the failure the
> change answers.

The job is narrow: install + verify. Do **not** configure or start the gateway —
that belongs to the `burrowee-gateway-setup` skill the operator invokes next.

The operator may need out-of-terminal actions (granting shell permissions, running
the printed `export PATH=…` line, opening a new shell to pick it up). Pause and
ask; resume on confirmation.

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
`burrowee` + `burrowee-gateway` + `burrowee-register` into `/usr/local/burrowee/bin`,
root-owned — since 0.2.0 that is the gateway's only destination, and the
installer elevates via `sudo` to place them (it prompts on the terminal, or
needs cached `sudo` credentials when run non-interactively). The gateway's
service units run as root and name these paths absolutely, and other components
resolve `/usr/local/burrowee/bin/burrowee` by absolute path, so a per-user copy would be
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
/usr/local/burrowee/bin/burrowee gateway version
```

`burrowee gateway version` prints `burrowee-gateway <version>`. That is the real,
source-backed version command for the component. **STOP here once a real version
line prints.**

> The unified `burrowee gateway version` and the bare `burrowee-gateway version`
> are equivalent — the dispatcher just execs the gateway component. Apart from
> `version`, `burrowee-gateway` is configured entirely by environment variables
> (covered in `burrowee-gateway-setup`) and starts running when invoked with no
> subcommand, and the registrar — reached as `burrowee register …`, since the bare
> `burrowee-register` is not linked onto PATH — takes `-sock`/`-name`/`-target`
> flags. Do not run a bare `burrowee gateway` here (it would try to start with
> missing env).

`/usr/local/burrowee/bin` is on nobody's PATH, so a fresh install ends with a
block naming the operator's own shell — for zsh:

```
==> Next steps
burrowee's commands are in /usr/local/burrowee/bin, which is not on your PATH.

  Add it to this shell now:
    export PATH="/usr/local/burrowee/bin:$PATH"

  Make it permanent:
    echo 'export PATH="/usr/local/burrowee/bin:$PATH"' >> /Users/<u>/.zprofile

  Then:  burrowee help
```

bash and fish get their own syntax and their own profile file; a shell the
installer cannot identify gets the export line and no file name. **Read the
block the install actually printed rather than reciting one** — it names the
invoking operator's shell and home, which is not necessarily root's or yours.
Until the operator runs it, use the full-path fallback above. If `burrowee` is
not found at `/usr/local/burrowee/bin` either, the install did not land — do
not work around it with a PATH edit.

An older host may also have `burrowee`, `burrowee-gateway` and
`burrowee-gateway-cli` in `/usr/local/bin`: releases up to the early 0.3 betas
linked them there when that directory was root-secure. See the version note at
the top. Those links are cleaned up by the install, not relied on.

Anything else (missing binary, "command not found" even by full path, wrong-arch
error) means the install didn't land — surface the output and stop.

---

## 3. Hand back

Once `burrowee gateway version` succeeds, **stop**. Tell the operator:

> burrowee gateway is installed at `/usr/local/burrowee/bin` (`burrowee` +
> `burrowee-gateway` + `burrowee-register`; the registrar is reached as
> `burrowee register …`). To configure its keys/PSK/relay and
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
  `sudo xattr -d com.apple.quarantine /usr/local/burrowee/bin/burrowee /usr/local/burrowee/bin/burrowee-gateway /usr/local/burrowee/bin/burrowee-register`.
- **Pin a specific version.** Re-run with `BURROWEE_GATEWAY_VERSION` set to a
  release tag:
  ```bash
  BURROWEE_GATEWAY_VERSION=gateway/v0.1.0.<stamp> \
    sh -c "$(curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/gateway/install.sh)"
  ```
- **Install somewhere else.** Not supported, and not silently ignored: the
  gateway installs to `/usr/local/burrowee/bin` and a set `PREFIX` aborts the install
  with a message saying so. If `PREFIX` is exported in the operator's shell
  profile for other tools, unset it for this command.
- **Uninstall.** Pass `BURROWEE_UNINSTALL=1` through the bootstrap; it removes
  `burrowee` + `burrowee-gateway` + `burrowee-register` from
  `/usr/local/burrowee/bin`, and clears any `/usr/local/bin` link an earlier
  0.3 release left behind (see the version note at the top):
  ```bash
  BURROWEE_UNINSTALL=1 \
    sh -c "$(curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/gateway/install.sh)"
  ```

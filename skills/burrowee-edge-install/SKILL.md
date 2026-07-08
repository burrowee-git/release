---
name: burrowee-edge-install
description: Install the burrowee-edge relay binary plus its companion burrowee-edge-cli setup tool on the user's own VPS (macOS + Linux). Use when the operator asks to "install burrowee edge", "get the edge relay binary", or pastes release.burrowee.com/skills/burrowee-edge-install/SKILL.md. Stop after the binary is on PATH and reports its version — pairing + run live in the burrowee-edge-setup skill, which the operator triggers next.
---

# burrowee-edge-install

You are an LLM coding agent installing the **burrowee-edge** binary on a user's own
VPS. An edge is a self-hosted, account-bound relay that serves only the owner's
gateways over the owner's custom domain, and is hard-bound to `console.burrowee.com`
(no `--console` override — the console identity is compiled in). This skill only gets
the binary onto PATH; pairing + run are in `burrowee-edge-setup`.

## 0. Pre-flight

```bash
uname -sm                          # OS + arch (e.g. "Linux x86_64", "Darwin arm64")
command -v burrowee-edge && burrowee-edge version || echo "not installed"
```

If `burrowee-edge version` already prints a real version line, the binary is
installed — route the operator straight to `burrowee-edge-setup` and stop.

---

## 1. Get the binary

**Preferred — GitHub Releases (when published):** download the asset matching the
host platform from the `burrowee.edge` releases (the burrowee release-repo pattern,
Doc 8 §5), `chmod +x`, move onto PATH (`/usr/local/bin` or `$HOME/.local/bin`).
Verify the checksum against the release `SHA256SUMS.txt` (use `shasum -a 256` on
macOS, `sha256sum` on Linux — detect either).

> If no release asset exists yet for the host platform, use the source build below.

**Source build (dev):**

```bash
git clone git@github.com:burrowee-git/edge.git
cd edge
# Linux (typical VPS):
go build -o burrowee-edge ./cmd/burrowee-edge
(cd cli && GOWORK=off go build -o ../burrowee-edge-cli .)
# macOS Burrowee dev tree only (a per-dir PATH hook strips /opt/homebrew/bin):
/opt/homebrew/bin/go build -o burrowee-edge ./cmd/burrowee-edge
(cd cli && GOWORK=off /opt/homebrew/bin/go build -o ../burrowee-edge-cli .)
```

The published GitHub-release installer ships `burrowee` (the dispatcher),
`burrowee-edge`, and `burrowee-edge-cli` together; a bare source build produces only
the two component binaries, so invoke the cli directly as `burrowee-edge-cli <cmd>`
(there is no dispatcher in a source build).

Move both resulting binaries — `burrowee-edge` and `burrowee-edge-cli` — onto PATH.

---

## 2. Verify

```bash
burrowee-edge version
```

Must print a real version line. If `burrowee-edge` isn't found, invoke it by full path to confirm it built:

```bash
$HOME/.local/bin/burrowee-edge version    # or /usr/local/bin/burrowee-edge version
```

If that works, the bin dir isn't on PATH — add `export PATH="$HOME/.local/bin:$PATH"` to your shell rc and open a new shell.

If it can't, the binary didn't build — resolve before continuing.

---

## 3. Note: nginx-fronted topology

nginx fronting is the **automatic default** for every new edge install. It is set up
in `burrowee-edge-setup` §5 (immediately after the service is running) — nothing to
do here at install time. A single `burrowee edge cli nginx install` (SNI/domain-fronted)
or `nginx apply` (LAN-only) command stands the front up: it writes and verifies the
nginx stream config (generating a 10-year LAN cert for the LAN-only path) and reloads
nginx. On Debian/Ubuntu the nginx stream module is a **separate package**
(`libnginx-mod-stream`); `doctor --fix` installs it automatically. The LAN port
(`:8448`) serves **wss** — TLS is terminated by nginx
using the locally-generated cert; gateways and CLIs authenticate it by pinned
fingerprint (distributed automatically via endpoint reports), not by a CA chain.

§5 covers both topologies: LAN-only (nginx `:8448` wss → edge `127.0.0.1:9448`,
`tls_listen=off`) and domain-fronted (adds nginx `:443` TCP passthrough → edge
`127.0.0.1:9443`, TLS inside the edge), including the port availability check and
operator port-conflict resolution.

---

## 4. Hand back

When `burrowee-edge version` works, tell the operator:

> burrowee-edge is installed. Next, run the **burrowee-edge-setup** skill to pair it
> to your Burrowee account, approve it, and start serving.

---

## Troubleshooting

- **`go build` fails with "no such package ./cmd/burrowee-edge".** You are not in the
  repo root — `cd` into the cloned `edge` checkout and re-run.
- **"command not found: go" while building.** On Linux, ensure Go is installed + on PATH. On the macOS Burrowee dev tree only, a per-dir hook strips `/opt/homebrew/bin` — use the absolute `/opt/homebrew/bin/go`.
- **(macOS only) Gatekeeper blocks the downloaded binary.** `xattr -d com.apple.quarantine ./burrowee-edge`.

---
name: burrowee-edge-install
description: Install the burrowee-edge relay binary on the user's own VPS (macOS + Linux). Use when the operator asks to "install burrowee edge", "get the edge relay binary", or pastes release.burrowee.com/skills/burrowee-edge-install/SKILL.md. Stop after the binary is on PATH and reports its version — pairing + run live in the burrowee-edge-setup skill, which the operator triggers next.
---

# burrowee-edge-install

> **STATUS — target guideline.** This skill drives the `burrowee-edge` CLI, which is
> part of the `burrowee.edge` *build subsystem* (spec §10) and is **not built yet**.
> Until it lands, treat this as the design target: the version/download commands below
> describe the intended UX. If `burrowee-edge` is absent and no source build exists,
> stop and route the operator to the build spec.

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

> Release assets do not exist until the CLI build + release pipeline land (spec §10).
> If there is no release yet, use the source build below.

**Source build (dev):**

```bash
git clone git@github.com:burrowee-git/edge.git
cd burrowee.edge
# Linux (typical VPS):
go build -o burrowee-edge ./cmd/burrowee-edge
# macOS Burrowee dev tree only (a per-dir PATH hook strips /opt/homebrew/bin):
/opt/homebrew/bin/go build -o burrowee-edge ./cmd/burrowee-edge
```

> `cmd/burrowee-edge` is the follow-on build (spec §10). If it is absent, the CLI is
> not built yet — stop and tell the operator the edge CLI is pending.

Move the resulting `burrowee-edge` onto PATH.

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

## 3. Hand back

When `burrowee-edge version` works, tell the operator:

> burrowee-edge is installed. Next, run the **burrowee-edge-setup** skill to pair it
> to your Burrowee account, approve it, and start serving.

---

## Troubleshooting

- **`go build` fails with "no such package ./cmd/burrowee-edge".** The CLI isn't
  built yet (spec §10). Stop; route to the build spec.
- **"command not found: go" while building.** On Linux, ensure Go is installed + on PATH. On the macOS Burrowee dev tree only, a per-dir hook strips `/opt/homebrew/bin` — use the absolute `/opt/homebrew/bin/go`.
- **(macOS only) Gatekeeper blocks the downloaded binary.** `xattr -d com.apple.quarantine ./burrowee-edge`.

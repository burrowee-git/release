---
name: burrowee-edge-install
description: Install the Burrowee edge binaries through an AI agent — downloads and minisign-verifies the release zip and places burrowee-edge-cli + burrowee-edge, by driving `burrowee-agent install edge`. Use when the user says "install burrowee edge", "get the edge relay binary", or pastes release.burrowee.com/skills/burrowee-edge-install/SKILL.md. Stop once the binaries are on disk — pairing + run live in burrowee-edge-setup, which auto-ensures install anyway.
---

# burrowee-edge-install

You are installing the **Burrowee edge** binaries for the user through the
`burrowee-agent` CLI. The agent downloads the release zip and minisign-verifies it
before placing anything — you NEVER fetch or run an unverified byte yourself; you
only run `burrowee-agent …` and relay its result.

This is the **agent** install path. The raw operator path (source build, hand-placing
a binary on PATH, manual checksum checks) is the manual fallback the agent verb
automates — do NOT drive that here.

> In most flows you do not need this skill on its own: **`burrowee-edge-setup`
> auto-ensures the install** as its first step. Run this only when the user wants to
> install without setting up yet, or to surface an install fault early.

## 0. Preflight — bound?
Run `burrowee-agent status`. If it reports `not bound`, stop and route to the
**`burrowee`** entry skill (install + bind first), then return here. (The component
install itself is purely local, but the rest of the edge flow needs a bound
identity, so confirm it up front.)

## 1. Run the install verb

```bash
burrowee-agent install edge
```

This resolves the latest edge release, downloads the per-component zip +
`SHA256SUMS.txt` + its minisig, verifies the **minisign signature** over the sums,
verifies the **zip's sha256** against the now-trusted sums, and only then unzips and
places the binaries under `~/.burrowee/agent/bin`:

- `burrowee-edge-cli` — the setup binary the agent drives (bootstrap / service /
  status / doctor). This is the binary the install returns the PATH of.
- `burrowee-edge` — the serving binary that the managed service registers (placed
  alongside the cli so `service install` finds it as its sibling).

A failed signature or checksum aborts **without installing anything**. On a platform
the native path does not ship, the agent falls back to the verified public
`install.sh`. It is idempotent — a second run with the binary already present is a
no-op.

## 2. Apply the next-action loop
Read the single line of JSON `burrowee-agent` prints on stdout and branch:

- `{"status":"done","summary":"installed edge","wrote":["…/burrowee-edge-cli"]}` →
  tell the user the edge binaries are installed; mention the `wrote` PATH by path
  only. Then route to **`burrowee-edge-setup`** to enroll + start the relay.
- `{"status":"error","code":"install_failed","message":"…"}` → surface `message`
  (a download, signature, or checksum failure). Nothing was installed — suggest
  re-running once the cause (network, platform support) is resolved.
- `{"status":"need_human",…}` → show the `message` + `url` and stop.

**Secret discipline:** never open or echo files the agent wrote. Refer to any
`wrote` path by path only.

## 3. Hand back
When `done`, tell the user:

> The Burrowee edge binaries are installed. Next, run **burrowee-edge-setup** to
> enroll the relay to your account, start it, and approve it.

(`burrowee-edge-setup` re-checks and re-ensures the install, so it is safe to go
straight there even without running this skill.)

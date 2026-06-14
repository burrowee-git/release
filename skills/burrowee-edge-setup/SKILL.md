---
name: burrowee-edge-setup
description: Stand up a self-hosted Burrowee edge relay through an AI agent — mints the relay, installs and starts the edge component, and approves it so it can carry traffic, by driving `burrowee-agent edge setup`. Use when the user says "set up an edge relay", "self-host a burrowee relay", "run my own relay", or pastes release.burrowee.com/skills/burrowee-edge-setup/SKILL.md.
---

# burrowee-edge-setup

You are standing up a self-hosted **Burrowee edge relay** for the user through the
`burrowee-agent` CLI: it mints the relay + sealed pairing material, writes the
secrets to local 0600 files, installs and starts the edge component, then approves
the relay — all inside the CLI. You NEVER handle keys, pairing blobs, or raw API
calls; you only run `burrowee-agent …` and relay its result.

## 0. Preflight — bound?
Run `burrowee-agent status`. If `not bound`, route to the **`burrowee`** entry skill
(install + bind first), then return here.

## 1. Run the setup verb + apply the next-action loop
Run:

```bash
burrowee-agent edge setup
```

Then apply the next-action loop below. Expect these decisions (gated one at a time):

- `hostname_base` — the hostname base the edge relay serves on (e.g. `edge-home`).
  Pass `--decision hostname_base=edge-home`.
- `service_mode` — `managed` (launchd/systemd unit) or `foreground`. Default
  `managed`. Pass `--decision service_mode=managed`.

Optional decisions the verb honors if supplied (no prompt is emitted for them):
`lan_mode=true` (LAN-only relay — never dials the cloud carrier), `region=<id>`,
`name=<label>`.

On `done` the edge relay is minted, installed, started, and approved; the `summary`
reads like `edge relay up: edge-home (<relay-id>)` with the secret file paths in
`wrote`. Mention those paths by PATH only, and tell the user the relay is now
carrying traffic for their tenant.

## 2. The next-action loop (self-contained)
After running any `burrowee-agent` workflow verb, read the single-line JSON it
prints on stdout and branch:

- `{"status":"done","summary":"…","wrote":["…"]}` → tell the user the `summary`.
  If `wrote` lists paths, mention them by PATH only — **never open or echo those
  files; they may be secrets.**
- `{"status":"need_decision","decision":{"id":"…","prompt":"…","options":[…],"default":"…"}}`
  → ask the user `decision.prompt` (offer `options`/`default` if present), then
  re-run the SAME verb adding `--decision <decision.id>=<answer>`, keeping prior
  decisions on the command line.
- `{"status":"need_human","reason":"…","message":"…","url":"…"}` → tell the user
  "this part needs you", show the `url`, and stop.
- `{"status":"error","code":"…","message":"…"}` → surface `message`; suggest
  re-running, or `burrowee edge doctor` for a component fault.

**Secret discipline:** never open or echo files the agent wrote — they may be
secrets. Refer to any `wrote` path by path only.

## 3. Related verb
- `burrowee-agent edge approve` — approve an already-minted pending relay by id;
  gates on the `relay_id` decision (`--decision relay_id=<id>`). Use this if a relay
  was minted earlier and is still pending.

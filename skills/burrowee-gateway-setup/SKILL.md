---
name: burrowee-gateway-setup
description: Stand up and enroll a Burrowee gateway through an AI agent — exposes a local service (SSH, a web app, …) over the relay, end to end, by driving `burrowee-agent gateway setup`. Use when the user says "set up a gateway", "expose my server with burrowee", "tunnel to this machine", or pastes release.burrowee.com/skills/burrowee-gateway-setup/SKILL.md.
---

# burrowee-gateway-setup

You are standing up a **Burrowee gateway** for the user through the `burrowee-agent`
CLI: it mints the enrollment material, writes the secrets to local 0600 files,
starts the gateway, and waits for the carrier to come up — all inside the CLI. You
NEVER handle keys, signatures, tokens, or raw API calls; you only run
`burrowee-agent …` and relay its result.

## 0. Preflight — bound? on the gateway box?
Run `burrowee-agent status`. If it reports `not bound`, stop and route to the
**`burrowee`** entry skill (install + bind first), then return here.

This verb runs **on the gateway box** — the machine whose service you're exposing.
If your agent isn't on it, apply the entry skill's topology rule first: `ssh` in and
run the flow there (install + bind `burrowee-agent` on that box first), or, if you
can't reach it, hand the steps off interactively. Everything below then runs on the
gateway box — locally or over SSH, the flow is identical.

## 1. Run the spine verb + apply the next-action loop
Run:

```bash
burrowee-agent gateway setup
```

Then apply the next-action loop below to its single line of JSON stdout. The verb
is idempotent and resumable — re-running with accumulated `--decision` flags is the
normal flow.

Expect these decisions (gated one at a time):

- `expose_target` — which local service to expose (the verb suggests options and
  defaults to `127.0.0.1:22` for SSH). Pass e.g.
  `--decision expose_target=127.0.0.1:22`.
- `service_mode` — `managed` (a launchd/systemd unit, survives reboot) or
  `foreground`. Default `managed`. Pass e.g. `--decision service_mode=managed`.

On `done` the gateway is enrolled, started, and the carrier is up; the `summary`
reads like `gateway up: target 127.0.0.1:22` and `wrote` lists the secret file
paths. Tell the user the target it now serves, mention the `wrote` paths by PATH
only, and that a client can connect next (route to **`burrowee-connect`**).

If `done` reads `gateway already set up`, it was already running — nothing to do.

## 2. The next-action loop (self-contained)
After running any `burrowee-agent` workflow verb, read the single-line JSON it
prints on stdout and branch:

- `{"status":"done","summary":"…","wrote":["…"]}` → tell the user the `summary`.
  If `wrote` lists paths, mention them by PATH only — **never open or echo those
  files; they may be secrets.**
- `{"status":"need_decision","decision":{"id":"…","prompt":"…","options":[…],"default":"…"}}`
  → ask the user `decision.prompt` (offer `options`/`default` if present), then
  re-run the SAME verb adding `--decision <decision.id>=<the user's answer>`, keeping
  any decisions already gathered on the command line.
- `{"status":"need_human","reason":"…","message":"…","url":"…"}` → tell the user
  "this part needs you", show the `message` + `url`, and stop.
- `{"status":"error","code":"…","message":"…"}` → surface `message`; suggest
  re-running, or `burrowee gateway doctor` for a component fault.

**Secret discipline:** never open or echo files the agent wrote — they may be
secrets. Refer to any `wrote` path by path only.

## 3. Related verbs
- `burrowee-agent gateway list` — list the account's gateways (emits `done` with a
  one-line summary).
- `burrowee-agent gateway rename <fingerprint>` — rename a gateway; gates on the
  `new_name` decision (`--decision new_name=…`).

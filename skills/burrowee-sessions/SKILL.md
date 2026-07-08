---
name: burrowee-sessions
description: List, share, create, and revoke Burrowee sessions through an AI agent, by driving `burrowee-agent session …`. Sharing returns a link; create/revoke run on the gateway box. Use when the user says "share a burrowee session", "list my sessions", "revoke a session", or pastes release.burrowee.com/skills/burrowee-sessions/SKILL.md.
---

# burrowee-sessions

You are managing the user's Burrowee sessions through the `burrowee-agent` CLI. You
NEVER handle keys, tokens, or raw API calls; you only run `burrowee-agent …` and
relay its result.

## 0. Preflight — bound?
Run `burrowee-agent status`. If `not bound`, route to the **`burrowee`** entry skill
(install + bind first), then return here.

## 1. List sessions
```bash
burrowee-agent session list
```
Emits `done` with a one-line summary of each session (id, service, active/revoked).
On a gateway box it reads the gateway's local console; otherwise it lists from the
cloud. Pass `--decision filter=mine|shared|all` to scope the cloud list.

## 2. Share a session + apply the next-action loop
Run:

```bash
burrowee-agent session share
```

Apply the next-action loop below. Expect these decisions (gated one at a time):

- `gateway_fp` — the fingerprint of the gateway that owns the session. Pass
  `--decision gateway_fp=<fingerprint>` (use `burrowee-agent gateway list` to find
  it).
- `sid` — the session id to share. Pass `--decision sid=<session-id>` (from
  `session list`).

On `done` the `summary` is `share link: <url>` — a NON-secret invitation URL. Give
that URL to the user to pass to whoever they're sharing with.

## 3. Create / revoke (gateway box only)
`session create` and `session revoke <sid>` run against the gateway's own local
console, so they only work **on the gateway machine**:

```bash
burrowee-agent session create
burrowee-agent session revoke <session-id>
```

Off the gateway box these return `{"status":"error","code":"not_on_gateway",…}` —
tell the user to run them on the gateway machine itself.

## 4. The next-action loop (self-contained)
After running any `burrowee-agent` workflow verb, read the single-line JSON it
prints on stdout and branch:

- `{"status":"done","summary":"…","wrote":["…"]}` → tell the user the `summary`
  (for `share`, that's the link). If `wrote` lists paths, mention them by PATH only
  — **never open or echo those files; they may be secrets.**
- `{"status":"need_decision","decision":{"id":"…","prompt":"…","options":[…],"default":"…"}}`
  → ask the user `decision.prompt`, then re-run the SAME verb adding
  `--decision <decision.id>=<answer>`, keeping prior decisions on the command line.
- `{"status":"need_human","reason":"…","message":"…","url":"…"}` → tell the user
  "this part needs you", show the `url`, and stop.
- `{"status":"error","code":"…","message":"…"}` → surface `message`. For
  `code:"not_on_gateway"`, tell the user to run it on the gateway box; otherwise
  suggest re-running.

**Secret discipline:** never open or echo files the agent wrote — they may be
secrets. Refer to any `wrote` path by path only.

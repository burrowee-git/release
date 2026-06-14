---
name: burrowee-domains
description: Attach and list custom (wildcard) domains on a Burrowee account through an AI agent, by driving `burrowee-agent domain add` / `domain list`. Plan-gated. Use when the user says "add a custom domain to burrowee", "use my own domain", "list my burrowee domains", or pastes release.burrowee.com/skills/burrowee-domains/SKILL.md.
---

# burrowee-domains

You are managing custom (wildcard) domains for the user through the `burrowee-agent`
CLI. Domain operations are cloud-only and plan-gated server-side. You NEVER handle
keys, signatures, or raw API calls; you only run `burrowee-agent …` and relay its
result.

## 0. Preflight — bound?
Run `burrowee-agent status`. If `not bound`, route to the **`burrowee`** entry skill
(install + bind first), then return here.

## 1. Add a domain + apply the next-action loop
Run:

```bash
burrowee-agent domain add
```

Apply the next-action loop below. Expect this decision:

- `apex` — the apex domain to verify (e.g. `example.com`). Pass
  `--decision apex=example.com`.

On `done` the domain is added (`summary` like `domain added: example.com (id 7)`).
The account then provisions a wildcard cert for it server-side; check progress with
`burrowee-agent domain list` (a domain shows `pending` until TLS is ready, then
`ready`).

**Plan limit:** if the verb returns `{"status":"error","code":"plan_limit",…}`,
tell the user custom domains are not included in their current plan — upgrading is a
human-only step (route to **`burrowee-account`**, which surfaces the upgrade URL via
`need_human`).

## 2. List domains
```bash
burrowee-agent domain list
```
Emits `done` with a one-line summary of each apex and its TLS status
(`pending`/`ready`).

## 3. The next-action loop (self-contained)
After running any `burrowee-agent` workflow verb, read the single-line JSON it
prints on stdout and branch:

- `{"status":"done","summary":"…","wrote":["…"]}` → tell the user the `summary`.
  If `wrote` lists paths, mention them by PATH only — **never open or echo those
  files; they may be secrets.**
- `{"status":"need_decision","decision":{"id":"apex","prompt":"…"}}` → ask the user
  for the apex domain, then re-run the verb adding `--decision apex=<answer>`.
- `{"status":"need_human","reason":"…","message":"…","url":"…"}` → tell the user
  "this part needs you", show the `url`, and stop.
- `{"status":"error","code":"…","message":"…"}` → surface `message`. For
  `code:"plan_limit"` tell the user the domain isn't in their plan; otherwise suggest
  re-running.

**Secret discipline:** never open or echo files the agent wrote — they may be
secrets. Refer to any `wrote` path by path only.

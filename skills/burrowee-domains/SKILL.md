---
name: burrowee-domains
description: Attach and list custom (wildcard) domains on a Burrowee account through an AI agent, by driving `burrowee-agent domain add` / `domain list`. Previews a plan, then applies it on your approval. Plan-gated. Use when the user says "add a custom domain to burrowee", "use my own domain", "list my burrowee domains", or pastes release.burrowee.com/skills/burrowee-domains/SKILL.md.
---

# burrowee-domains

You are managing custom (wildcard) domains for the user through the `burrowee-agent`
CLI. Domain operations are cloud-only and plan-gated server-side. You NEVER handle
keys, signatures, or raw API calls; you only run `burrowee-agent …` and relay its
result.

This skill works in three phases — **plan → approve once → run**: you preview the
exact change (server-validated, nothing committed), the user approves once, then you
apply it.

## 0. Preflight — bound?
Run `burrowee-agent status`. If `not bound`, route to the **`burrowee`** entry skill
(install + bind first), then return here.

## 1. Add a domain — plan → approve → run

**Plan.** Ask the user which apex domain to add (e.g. `example.com`), then dry-run it:

```bash
burrowee-agent domain add --plan --decision apex=<apex>
```

Read the single-line JSON (see §3). On `{"status":"plan","summary":"…","plan":[…]}`,
present each planned op to the user — its action, resolved args, and flags. For a
domain add this is one op, rendered like:

> I'll **add the `example.com` wildcard domain** — plan-gated, reversible.

If you don't yet know the apex, run `burrowee-agent domain add --plan` with no
`--decision`; the verb replies `need_decision` asking for `apex` — ask the user, then
re-run the `--plan` with `--decision apex=<answer>`.

**Approve once.** Ask the user to approve the plan ("Go ahead?"). If they change the
apex, re-run the Plan step with the new `--decision`. Do not proceed without a yes.

**Run.** Apply the approved change (same verb, no `--plan`):

```bash
burrowee-agent domain add --decision apex=<apex>
```

On `done` the domain is added (`summary` like `domain added: example.com (id 7)`).
The account then provisions a wildcard cert for it server-side; check progress with
`burrowee-agent domain list` (a domain shows `pending` until TLS is ready, then
`ready`).

**Plan limit:** if either the `--plan` or the run returns
`{"status":"error","code":"plan_limit",…}`, tell the user custom domains are not
included in their current plan — upgrading is a human-only step (route to
**`burrowee-account`**, which surfaces the upgrade URL via `need_human`).

## 2. List domains
```bash
burrowee-agent domain list
```
Read-only — no plan needed. Emits `done` with a one-line summary of each apex and its
TLS status (`pending`/`ready`).

## 3. The next-action loop (self-contained)
After running any `burrowee-agent` workflow verb — in the Plan phase (`--plan`) or the
Run phase — read the single-line JSON it prints on stdout and branch:

- `{"status":"plan","summary":"…","plan":[{"verb":"…","args":{…},"reversible":…,"plan_gated":…}]}`
  → (Plan phase) render each op for the user — action, resolved `args`, and the
  `reversible`/`plan_gated` flags — then go to **Approve once**.
- `{"status":"done","summary":"…","wrote":["…"]}` → (Run phase) tell the user the
  `summary`. If `wrote` lists paths, mention them by PATH only — **never open or echo
  those files; they may be secrets.**
- `{"status":"need_decision","decision":{"id":"apex","prompt":"…"}}` → ask the user
  for the value, then re-run the verb adding `--decision <id>=<answer>` (keep `--plan`
  if you were planning).
- `{"status":"need_human","reason":"…","message":"…","url":"…"}` → tell the user
  "this part needs you", show the `url`, and stop until they finish, then resume.
- `{"status":"error","code":"…","message":"…"}` → surface `message`. For
  `code:"plan_limit"` tell the user the domain isn't in their plan; otherwise suggest
  re-running.

**Secret discipline:** never open or echo files the agent wrote — they may be
secrets. Refer to any `wrote` path by path only. A plan's `args` carry only resolved,
non-secret values.

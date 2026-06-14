---
name: burrowee-account
description: View and manage Burrowee account and team settings through an AI agent, by driving `burrowee-agent account …` and `team …`. Billing, plan upgrade, and account deletion are handed back to the human. Use when the user says "show my burrowee account", "manage my team", "add a teammate", "upgrade my plan", or pastes release.burrowee.com/skills/burrowee-account/SKILL.md.
---

# burrowee-account

You are managing the user's Burrowee account and teams through the `burrowee-agent`
CLI. Reads are R1; writes (account set, team operations) are R2 — the bound key's
role is enforced by the server. You NEVER handle keys, tokens, or raw API calls; you
only run `burrowee-agent …` and relay its result.

## 0. Preflight — bound?
Run `burrowee-agent status`. If `not bound`, route to the **`burrowee`** entry skill
(install + bind first), then return here.

## 1. Account
```bash
burrowee-agent account show          # R1 — plan, status, tenant, GitHub login/email
burrowee-agent account set --decision <field>=<value>   # R2 — profile patch
```
`account show` emits `done` with a one-line account summary. `account set` PATCHes
the profile from the `--decision` key/values you pass (a forward-compatible patch;
an empty patch re-returns the current envelope).

## 2. Teams
```bash
burrowee-agent team list                                  # R2
burrowee-agent team create --decision team_name=<name>    # R2
burrowee-agent team member add <team_id> --decision member_login=<github-login>
#                                         optional: --decision member_role=admin
```
`team create` gates on the `team_name` decision; `team member add` takes the team id
as a positional and gates on `member_login` (role defaults to `member`). Each emits
the next-action JSON.

## 3. Human-only operations (R3)
Billing, plan upgrade, and account deletion are never attempted by the agent. These
verbs return `need_human` with a console URL:

```bash
burrowee-agent account billing       # → need_human, billing URL
burrowee-agent account upgrade       # → need_human, upgrade URL
burrowee-agent account delete        # → need_human, account URL
```

On `need_human`, tell the user "this part needs you", show the `message` + `url`,
and do not proceed.

## 4. The next-action loop (self-contained)
After running any `burrowee-agent` workflow verb, read the single-line JSON it
prints on stdout and branch:

- `{"status":"done","summary":"…","wrote":["…"]}` → tell the user the `summary`.
  If `wrote` lists paths, mention them by PATH only — **never open or echo those
  files; they may be secrets.**
- `{"status":"need_decision","decision":{"id":"…","prompt":"…","options":[…],"default":"…"}}`
  → ask the user `decision.prompt`, then re-run the SAME verb adding
  `--decision <decision.id>=<answer>`, keeping prior decisions on the command line.
- `{"status":"need_human","reason":"…","message":"…","url":"…"}` → tell the user
  "this part needs you", show the `message` + `url`, and stop (billing / upgrade /
  delete always land here).
- `{"status":"error","code":"…","message":"…"}` → surface `message`. A role error
  (an R1 key attempting an R2 write) means the bound key isn't admin — the user
  would need to bind an R2 key.

**Secret discipline:** never open or echo files the agent wrote — they may be
secrets. Refer to any `wrote` path by path only.

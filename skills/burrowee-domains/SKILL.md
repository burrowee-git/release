---
name: burrowee-domains
description: Attach and list custom (wildcard) domains on a Burrowee account through an AI agent, by driving `burrowee-agent domain add` / `domain list`. Plan-gated; add runs plan → approve once → run. Use when the user says "add a custom domain to burrowee", "use my own domain", "list my burrowee domains", or pastes release.burrowee.com/skills/burrowee-domains/SKILL.md.
---

# burrowee-domains

You are managing custom (wildcard) domains for the user through the `burrowee-agent`
CLI. Domain operations are cloud-only and plan-gated server-side. You NEVER handle
keys, signatures, or raw API calls; you only run `burrowee-agent …` and relay its
result.

## 0. Preflight — bound?
Run `burrowee-agent status`. If `not bound`, route to the **`burrowee`** entry skill
(install + bind first), then return here.

## 1. Add a domain — plan → approve once → run
Adding a domain mutates the account, so it runs in three phases (§3). `domain add`
supports `--plan`, so use the full flow:

1. **Plan.** Ask the user which apex domain they want to attach (e.g.
   `example.com`), then dry-run it:

   ```bash
   burrowee-agent domain add --plan --decision apex=example.com
   ```

   On `{"status":"plan","summary":"…","plan":[…]}`, present the planned op to the
   user in plain language — for the one op it returns:

   > I'll **add the `example.com` wildcard domain** — plan-gated, reversible.

   (Read the op's `verb`/`args` and its `reversible`/`plan_gated` flags from the
   `plan` array.) If the dry-run returns `need_decision` instead, an input is still
   missing — ask for it, add the `--decision`, and re-run the `--plan`.

2. **Approve once.** Ask the user to approve ("Go ahead?"). If they change the apex,
   re-run Phase 1 with the new `--decision`. Do not proceed without an explicit yes.

3. **Run.** Execute the same verb WITHOUT `--plan`, carrying the same decision:

   ```bash
   burrowee-agent domain add --decision apex=example.com
   ```

   On `done` the domain is added (`summary` like `domain added: example.com (id 7)`).
   The account then provisions a wildcard cert server-side; check progress with
   `burrowee-agent domain list` (a domain shows `pending` until TLS is ready, then
   `ready`).

**Plan limit:** if either phase returns `{"status":"error","code":"plan_limit",…}`,
tell the user custom domains are not included in their current plan — upgrading is a
human-only step (route to **`burrowee-account`**, which surfaces the upgrade URL via
`need_human`). The `--plan` dry-run surfaces this before any change, so the user
learns it at approve time, not mid-run.

## 2. List domains
```bash
burrowee-agent domain list
```
Read-only — no plan phase (nothing to commit). Emits `done` with a one-line summary
of each apex and its TLS status (`pending`/`ready`).

## 3. The plan → approve once → run control flow (self-contained)
Every mutating `burrowee-agent` workflow runs as Plan → Approve once → Run. Read the
single-line JSON each verb prints on stdout and branch:

- `{"status":"plan","summary":"…","plan":[…]}` → **(Plan phase)** render each op in
  the `plan` array — its action (`verb`), resolved `args`, and `reversible` /
  `plan_gated` flags — as a readable list, then go to **Approve once**. A `plan`'s
  `args` carry only resolved, non-secret values.
- `{"status":"done","summary":"…","wrote":["…"]}` → **(Run phase)** tell the user the
  `summary`. If `wrote` lists paths, mention them by PATH only — **never open or echo
  those files; they may be secrets.**
- `{"status":"need_decision","decision":{"id":"…","prompt":"…"}}` → ask the `prompt`
  (offer any `options`/`default`), then re-run the verb adding `--decision <id>=<answer>`.
- `{"status":"need_human","reason":"…","message":"…","url":"…"}` → tell the user
  "this part needs you", show the `url`, stop until they finish, then resume.
- `{"status":"error","code":"…","message":"…"}` → surface `message`. For
  `code:"plan_limit"` tell the user the domain isn't in their plan; otherwise suggest
  a fix or `burrowee-agent domain doctor`.

**Approve once** (between Plan and Run): ask the user to approve the whole plan. If
they amend an input, re-run the Plan phase with the new `--decision`. Never run the
committing verb without an explicit yes.

### 3.1 Fallback when a verb has no `--plan` yet
If `burrowee-agent <verb> --plan` returns an error indicating the flag is unknown,
that verb has not been migrated yet — run it directly under the branch above (the
per-action loop), gathering decisions as they are asked. `domain add` supports
`--plan` today, so this skill uses the full flow above; the fallback is here only for
forward-compatibility.

**Secret discipline:** never open or echo files the agent wrote — they may be
secrets. Refer to any `wrote` path by path only; a `plan`'s `args` are non-secret.

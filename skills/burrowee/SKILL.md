---
name: burrowee
description: Set up and use Burrowee remote access through an AI agent — installs the burrowee-agent CLI, binds it to your Burrowee account (GitHub), then routes to the per-task skills. Use when the user says "set up burrowee", "connect burrowee", "give me remote access with burrowee", or pastes ai.burrowee.com.
---

# burrowee

You are driving Burrowee setup for the user through the `burrowee-agent` CLI. You
NEVER handle keys, signatures, tokens, or raw API calls — you only run
`burrowee-agent …` commands; the CLI does all crypto + HTTP internally. A leaked
or prompt-injected context therefore contains nothing reusable: the private key
stays on the machine, inside the CLI process.

The binary is `burrowee-agent`; invoke it directly (`burrowee-agent <verb>`) — the
universal `burrowee` dispatcher also routes the `agent` word now
(`burrowee agent <verb>` ⇔ `burrowee-agent <verb>`, plain pass-through, no verb
split), so either form works. It is the open-source signing client.

## 0. Install the CLI
Run `burrowee-agent version`. If it prints a version line, skip to §1. If the
command is missing, install it (the binary lands on PATH as `burrowee-agent`):

```bash
curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/agent/install.sh | sh
burrowee-agent version
```

(If your platform package channel differs, fetch the entry from
`ai.burrowee.com/llms.txt` — it carries the current install one-liner.)

## 1. Bind to an account
Run `burrowee-agent status` (local, no network) — if it prints a bound identity
(`fingerprint=…`), skip to §3. Otherwise bind. Binding is the ONE human touch and
the only step the agent cannot complete alone:

- **New account:** `burrowee-agent bootstrap` — it prints a verification URL. Give
  that URL to the user; they approve via GitHub. The first agent on a new account
  becomes R2 (admin). On approval it prints `Bound: fingerprint=… role=… tenant=…`.
- **Existing account:** `burrowee-agent bind` — it prints a URL **and a short
  user-code**; the user opens the URL, signs in, finds the pending key by that code,
  picks its tier, and approves. Then it prints `Bound: …`.

`bootstrap`/`bind`/`status`/`whoami` print plain human-readable lines (not the
next-action JSON below) — relay them as-is. The control-plane URL has no
compiled-in default — pass `--url` or set `BURROWEE_CONTROL_PLANE_URL` to the
production console, `https://console.burrowee.com`.

## 2. The next-action loop (use this for EVERY workflow verb)
The workflow verbs — `gateway`, `cli`, `edge`, `domain`, `session`, `account`,
`team` — each print a single line of JSON on stdout describing exactly one outcome.
After running any such `burrowee-agent <verb>`, read that line and branch:

- `{"status":"done","summary":"…","wrote":["…"]}` → tell the user the `summary`.
  If `wrote` lists paths, mention them by PATH only — **never open or echo those
  files; they may be secrets.**
- `{"status":"need_decision","decision":{"id":"…","prompt":"…","options":[…],"default":"…"}}`
  → ask the user `decision.prompt` (offer `options`/`default` if present), then
  re-run the SAME verb adding `--decision <decision.id>=<the user's answer>`. Keep
  prior decisions on the command line; the verb gates one decision at a time.
- `{"status":"need_human","reason":"…","message":"…","url":"…"}` → tell the user
  "this part needs you", show the `message` + `url`, and do not try to proceed.
- `{"status":"error","code":"…","message":"…"}` → surface `message`; for a
  component error suggest re-running, and for `code:"plan_limit"` tell the user the
  operation isn't in their plan.

**Secret discipline (restate to yourself every time):** never open or echo files
the agent wrote — they may be secrets. Refer to any `wrote` path by path only.

## 3. Where is your agent (you) running? — decide the plane before routing
Burrowee spans up to three machines, each running its own bound `burrowee-agent`:
the **gateway box** (the machine whose service you expose; it also mints cli pairing
blobs), an optional **edge host** (a self-hosted relay), and the **client box**
(where `burrowee-cli` connects from). Each task runs on its own box — `gateway
setup` on the gateway, `edge setup` on the edge host, `cli pair` on the client — so
before routing, ask the user plainly:

> "Is this agent running on the machine you want to expose (the gateway), on the
> client you'll connect from, or a third box?"

Then, for each box a task needs, apply ONE rule:

- **It's the box you're on** → run the verb locally, the normal way.
- **You can SSH to it** → do the work THERE as if local: `ssh` in, install
  `burrowee-agent` (§0 one-liner) and bind it on that box (the user approves that
  box's key in the browser — one human touch per box), then run the same setup verb
  over `ssh user@host '…'`. The §2 next-action loop is identical — the CLI does all
  crypto on that box. Keep secret files on that box, or move them **file-to-file
  with `scp`**, never through this conversation.
- **You cannot reach it** → hand it off with the interactive loop below. Never run
  what you can't run, and never ask the user to paste a secret to you.

### Interactive hand-off loop (for any step on a box you can't reach)
Give the user **exactly one** command or action, and say what success looks like.
Then STOP and wait — let them run it and report back (paste output, or say "done").
Read the result: on success, give the next step; on error, diagnose and hand back a
corrected one. Repeat until the task reaches its `done`. Never dump the whole
sequence at once — one step, confirm, next.

## 4. Route to what the user wants
- stand up a gateway / expose a service → `burrowee-gateway-setup` skill
- pair the cli / SSH or connect to a gateway → `burrowee-connect` skill
- self-hosted edge relay → `burrowee-edge-setup` skill
- attach a custom domain → `burrowee-domains` skill
- list / share / manage sessions → `burrowee-sessions` skill
- account or team settings → `burrowee-account` skill

Each workflow skill is self-contained (it re-embeds this loop), so load just the
one the user needs.

---
name: burrowee-connect
description: Pair the Burrowee cli to a gateway through an AI agent, then connect or SSH to the exposed service. Drives `burrowee-agent cli pair`, then the `burrowee-cli` binary for the actual connection. Use when the user says "connect to my gateway", "SSH through burrowee", "pair the cli", or pastes release.burrowee.com/skills/burrowee-connect/SKILL.md.
---

# burrowee-connect

You are pairing the user's local **burrowee-cli** to a gateway and opening a
connection. Pairing runs through the `burrowee-agent` CLI (it writes the pairing
material to a local 0600 file and drives `burrowee-cli`); the connection itself is
run directly by the `burrowee-cli` binary. You NEVER handle keys, blobs, or raw API
calls — `burrowee-agent` does all crypto + IO internally.

## 0. Preflight — bound?
Run `burrowee-agent status`. If `not bound`, route to the **`burrowee`** entry skill
(install + bind first), then return.

## 1. Pair the cli (local plane)
The cli pairing blob is minted by the **gateway's own loopback console**, not the
cloud — it never leaves the gateway box. So obtain the blob first:

> On the gateway machine, open its local console (loopback,
> `http://127.0.0.1:16518` by default) and have it mint a cli pairing blob; paste
> that blob here.

Then run, supplying the blob as the `pairing_blob` decision:

```bash
burrowee-agent cli pair --decision pairing_blob=<the-blob-from-the-gateway>
```

Apply the next-action loop. If you run `burrowee-agent cli pair` with no decision,
it returns `need_decision` for `pairing_blob` — ask the user for the gateway's blob
and re-run with it. On `done` the cli is paired (`summary: "cli paired"`, with the
written path in `wrote` — mention it by path only).

## 2. Connect or SSH (run via the cli binary)
`connect` and `ssh` are NOT `burrowee-agent` verbs — once paired, run the
`burrowee-cli` binary directly (the universal dispatcher also routes the bare words
`connect`/`ssh` to `burrowee-cli`):

```bash
# open a tunnel to an exposed target (default service if --svc omitted):
burrowee-cli connect <gateway>[:<target>]

# SSH through the gateway to its SSH target:
burrowee-cli ssh <gateway>
```

Run `burrowee-cli connect --help` / `burrowee-cli ssh --help` for the exact flags
on the installed version (e.g. `--svc <service-name>` to pick a named target).

## 3. The next-action loop (self-contained — for the `cli pair` verb)
After running `burrowee-agent cli pair`, read the single-line JSON it prints and
branch:

- `{"status":"done","summary":"…","wrote":["…"]}` → tell the user the `summary`.
  If `wrote` lists paths, mention them by PATH only — **never open or echo those
  files; they may be secrets.**
- `{"status":"need_decision","decision":{"id":"pairing_blob","prompt":"…"}}` → ask
  the user for the gateway's pairing blob, then re-run the verb adding
  `--decision pairing_blob=<answer>`.
- `{"status":"need_human","reason":"…","message":"…","url":"…"}` → tell the user
  "this part needs you", show the `url`, and stop.
- `{"status":"error","code":"…","message":"…"}` → surface `message`; suggest
  re-running. If pairing fails, confirm the blob came from the right gateway's
  loopback console.

**Secret discipline:** never open or echo files the agent wrote — they may be
secrets. Refer to any `wrote` path by path only.

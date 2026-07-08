---
name: burrowee-edge-setup
description: Stand up a self-hosted Burrowee edge relay end to end through an AI agent — install the edge binaries, mint + enroll the relay, start it, approve it, then poll status and run doctor — all by driving `burrowee-agent edge …`. Use when the user says "set up an edge relay", "self-host a burrowee relay", "run my own relay", or pastes release.burrowee.com/skills/burrowee-edge-setup/SKILL.md.
---

# burrowee-edge-setup

You are standing up a self-hosted **Burrowee edge relay** for the user, end to end,
through the `burrowee-agent` CLI. An edge is a self-hosted, account-bound relay that
serves only the owner's gateways over the owner's custom domain. The agent verb does
the whole flow inside the CLI: it ensures the edge binaries are installed
(download + minisign-verify), mints the relay + sealed pairing material, writes the
secrets to local 0600 files, runs the enroll/bootstrap + nginx-front setup, starts
the edge, then approves the relay so it can carry traffic. You NEVER handle keys,
pairing blobs, certs, or raw API calls — you only run `burrowee-agent …` (and the
`burrowee-edge-cli` it installs, for the read-only status/doctor checks) and relay
the result.

This skill is the **agent** path. The raw operator commands (`burrowee edge cli
bootstrap …`, hand-pasting a blob + PIN from the console portal) are the manual
fallback the agent verb automates — do NOT drive those here; drive `burrowee-agent`.

## 0. Preflight — bound?
Run `burrowee-agent status`. If it reports `not bound`, stop and route to the
**`burrowee`** entry skill (install + bind first), then return here.

## 1. (Optional) Ensure the edge binaries are installed
`burrowee-agent edge setup` auto-ensures the install as its first step, so you can
skip straight to §2. Run a standalone install only if the user asked to install
without setting up yet, or to surface an install fault early:

```bash
burrowee-agent install edge
```

This downloads the edge release zip and minisign-verifies it, placing **both**
`burrowee-edge-cli` (the setup binary the agent drives) and `burrowee-edge` (the
serving binary its managed service registers) under `~/.burrowee/agent/bin`. It
emits a `done` next-action whose `wrote` carries the installed binary PATH — apply
the loop in §3. (Trust chain: minisign signature over `SHA256SUMS.txt`, then the
zip's sha256 against the now-trusted sums — the same chain the public install.sh
runs, headless.)

## 2. Run the setup verb + apply the next-action loop
Run:

```bash
burrowee-agent edge setup
```

Then apply the next-action loop in §3. The verb is idempotent and resumable —
re-running with accumulated `--decision` flags is the normal flow. In ONE verb it
auto-ensures the install (§1), mints + enrolls the relay, runs bootstrap (which also
stands up the nginx LAN front automatically), starts the edge per `service_mode`,
and approves the relay.

Expect these decisions (gated one at a time):

- `hostname_base` — the public hostname base this edge serves on (e.g. `edge-home`).
  Pass `--decision hostname_base=edge-home`.
- `service_mode` — `managed` (a launchd/systemd unit that survives reboot, the
  recommended choice for an always-on VPS) or `foreground` (recommended for
  first-run / debugging — the bootstrap enrolls but installs no service). Default
  `managed`. Pass `--decision service_mode=managed`.

Optional decisions the verb honors if supplied (no prompt is emitted for them):
`lan_mode=true` (LAN-only relay — never dials the cloud carrier), `region=<id>`,
`name=<label>`.

On `done` the edge relay is installed, enrolled, started, and approved; the
`summary` reads like `edge relay up: edge-home (<relay-id>)` with the secret file
paths in `wrote`. Mention those paths by PATH only, and tell the user the relay is
now carrying traffic for their tenant. Then run the §4 verify.

## 3. The next-action loop (self-contained)
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
- `{"status":"error","code":"…","message":"…"}` → surface `message`. On
  `install_failed`, re-run `burrowee-agent install edge` to see the download/verify
  fault. On `edge_install_failed`, the bootstrap or service install failed — run
  the §5 doctor. Otherwise suggest re-running the verb.

**Secret discipline:** never open or echo files the agent wrote — they may be
secrets. Refer to any `wrote` path by path only.

## 4. Verify — status poll
`burrowee-agent edge setup` mints, enrolls, and approves the relay, but the
console's **signed config** (tenant, served domains, gateway caps) lands over the
carrier only once the edge is connected. Poll the installed setup binary's
read-only status until that config arrives:

```bash
burrowee-edge-cli status
```

(It lives next to the agent's installed binaries — invoke
`"$HOME/.burrowee/agent/bin/burrowee-edge-cli" status` if it is not on PATH.)
Before the config lands it prints `enrolled; no config received yet (...)`; once
approved + connected it prints the signed-config dump (`owner tenant:`,
`served domains:`, `max gateways:`, …). Repeat every few seconds until it prints the
dump — that confirms the relay is live and carrying the tenant's config. This is a
read-only check; it handles no secrets.

## 5. Doctor — if anything looks wrong
For a health check or to remediate the nginx front (e.g. after an `edge_install_failed`
error, or if the relay isn't reachable), run the installed setup binary's doctor:

```bash
burrowee-edge-cli doctor          # read-only: identity / console reachable / nginx front
burrowee-edge-cli doctor --fix    # bring the nginx LAN front up (install → apply → start)
```

On Linux the `--fix` path needs root for the nginx install + enable, and `--home`
because sudo swaps `$HOME`:

```bash
sudo "$(command -v burrowee-edge-cli)" doctor --fix --yes --home "$HOME/.burrowee/edge"
```

Report each `doctor` line back to the user; `--fix` is safe to re-run.

## 6. Related verb
- `burrowee-agent edge approve` — approve an already-minted pending relay by id;
  gates on the `relay_id` decision (`--decision relay_id=<id>`). Use this if a relay
  was minted earlier and is still pending (apply the §3 loop to its output).

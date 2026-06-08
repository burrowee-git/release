---
name: burrowee-edge-setup
description: Pair an installed burrowee-edge relay to your Burrowee account, approve it, run it (managed service or foreground), attach a custom domain, and verify. Use after the burrowee-edge binary is installed (see burrowee-edge-install). Trigger when the operator says "set up burrowee edge", "pair my edge relay", "connect edge to my account", or pastes release.burrowee.com/skills/burrowee-edge-setup/SKILL.md.
---

# burrowee-edge-setup

> **STATUS — target guideline.** Drives the `burrowee-edge` CLI + the owner-tier
> "Edge relays" portal section, both part of the `burrowee.edge` build subsystem
> (spec §10) and **not built yet**. The pairing flow it documents (mint → enroll →
> approve → carrier) is already implemented in console + relay (spec §4); this skill
> becomes runnable when the CLI + portal section land. Until then it is the design
> target.

You are an LLM coding agent setting up an already-installed **burrowee-edge** relay
against `console.burrowee.com`. The binary must be on PATH — if not, route to
`burrowee-edge-install` and stop.

This skill **requires interactive operator steps** (portal mint, explicit approve,
service-vs-foreground choice). Pause and ask; resume on confirmation.

The edge is **hard-bound to `console.burrowee.com`** — there is no console-selection
flag. If the operator needs a different console, that is a different (dev) build.

## 0. Pre-flight

```bash
burrowee-edge version
ls -ld "$HOME/.burrowee-edge" 2>/dev/null || echo "no .burrowee-edge dir"
```

`burrowee-edge version` must print a real version line (else → burrowee-edge-install).
If `$HOME/.burrowee-edge` already holds an identity from a prior pairing, ask the
operator: keep that identity (just re-pair/refresh) or wipe and start over.

---

## 1. Mint the edge in the portal (operator step)

Tell the operator:

> Open `https://console.burrowee.com`, go to **Edge relays → Add edge relay**, enter
> the public hostname this box will serve on (its `hostname_base`), and copy the
> **pairing code** it shows. Paste that code back here.

Wait for the pairing code. (Backend: `POST /api/v1/relays {hostname_base}` →
`{relay_id, blob, pin, salt}`, owner-tier — spec §4 ①, §7.)

---

## 2. Enroll

```bash
burrowee-edge enroll <pairing-code>
```

This generates the edge's Ed25519 identity (private key never leaves the box),
decodes the enroll secret, and runs the one-shot enroll handshake against
`console.burrowee.com`. On success it prints the edge **fingerprint** and
`awaiting approval`. Record the fingerprint — the operator approves *that exact*
fingerprint next. (Backend: the one-shot enroll handshake presents the self-pubkey + sealed secret; **console** binds the pubkey to the pending row, then the identity handshake loops on `relay-pending` — spec §4 ②.)

---

## 3. Approve (operator step)

Tell the operator:

> Back in `console.burrowee.com → Edge relays`, find the pending edge with fingerprint
> `<fingerprint from step 2>` and click **Approve**.

Then poll until active:

```bash
burrowee-edge status        # repeat until state shows "active"
```

(Backend: `GET /api/v1/relays/pending` + `POST /api/v1/relays/{id}/approve`,
owner-owns check — spec §4 ③.) Do not proceed until `status` is `active`.

---

## 4. Run: managed service vs foreground

Ask the operator; don't pick for them.

**Option A — managed service (recommended for an always-on VPS):**

```bash
burrowee-edge service install
burrowee-edge service status        # confirm loaded/started
```

Writes the launchd plist (macOS) / systemd unit (Linux) and bootstraps it; the
edge survives reboot.

**Option B — foreground (recommended for first-run / debugging):**

> Open a separate terminal and run `burrowee-edge run`. Leave it running; switch
> back when you see the carrier connect to `console.burrowee.com`.

Do **not** background `burrowee-edge run` from this skill's shell — its logs are the
operator's primary debugging surface. Wait for the operator to confirm it's up.

---

## 5. Attach a custom domain

The edge serves **custom domains only**. Tell the operator:

> In `console.burrowee.com → Edge relays → <this edge> → Attach domain`, claim your
> domain for a gateway + service. The portal shows two DNS records. Publish both at
> any DNS host:
> - `<your-domain>`            A/CNAME → this edge's public address
> - `_acme-challenge.<domain>` CNAME  → `<slug>.acme.burrowee.net`

Then poll for the cert:

```bash
burrowee-edge doctor        # watch the "custom-domain cert" line flip to ✓
```

(Backend: the `acme.burrowee.net` certbot DNS-01 pipeline issues the LE cert, console
seals it + pushes it to this edge via `relay/cert/upsert`, and pushes the
`hostname→(gateway_fp, svc)` route via `relay/route/upsert` — spec §9.)

> **Web serving:** the relay's `:443` Host-ingress proxies browser requests to the
> gateway via the core `WebOpen` frame (C0 **W4**, merged 2026-06-04), so custom-domain
> **web viewers** work once the cert + route land — same as raw TCP/SSH. (Edge builds
> from a pre-W4 relay served raw TCP/SSH only.)

---

## 6. Verify

```bash
burrowee-edge doctor        # every line ✓
```

Confirm the carrier is up (heartbeat), enroll state `active`, TLS listener up, and
the custom-domain cert present. Then confirm end-to-end through the custom domain —
a raw TCP/SSH connect, or a browser request for a web service (the `:443` W4
web-ingress is live).

---

## 7. Hand back

When green, tell the operator:

> Your edge is paired and serving. Useful commands:
> - `burrowee-edge status` — enroll state, tenant, served domains, caps
> - `burrowee-edge doctor` — re-verify any time
> - Service logs (macOS): `tail -f $HOME/.burrowee-edge/logs/launchd.out.log`
> - Service logs (linux): `journalctl --user -u burrowee-edge.service -f`
>
> Adding more domains/services happens in `console.burrowee.com → Edge relays`.

---

## Troubleshooting hooks

- **"awaiting approval" never flips to active.** The operator approved a *different*
  edge, or is signed into the wrong account. Confirm the fingerprint in the portal
  matches step 2; confirm they're the owner-tier account that minted it.
- **Console unreachable.** The edge only talks to `console.burrowee.com` (compiled in —
  no override). Check the VPS's outbound HTTPS/WSS to `console.burrowee.com`; honor
  `HTTPS_PROXY` if behind a proxy.
- **`doctor` shows custom-domain cert ✗ for a while.** DNS propagation + LE issuance
  take time; the `_acme-challenge` CNAME must resolve to `<slug>.acme.burrowee.net`.
  Re-run `doctor` after a few minutes.
- **Re-pair from scratch.** `rm -rf $HOME/.burrowee-edge` then re-run from step 1.
  This wipes the identity; the console-side pending row must be re-minted.
- **`service install` fails: systemd not available.** Non-systemd init (OpenRC,
  runit) — fall back to Option B (foreground) or a custom supervisor.

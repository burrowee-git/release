---
name: burrowee-edge-setup
description: Pair an installed burrowee-edge relay to your Burrowee account, approve it, run it (managed service or foreground), attach a custom domain, and verify. Use after the burrowee-edge binary is installed (see burrowee-edge-install). Trigger when the operator says "set up burrowee edge", "pair my edge relay", "connect edge to my account", or pastes release.burrowee.com/skills/burrowee-edge-setup/SKILL.md.
---

# burrowee-edge-setup

You are an LLM coding agent setting up an already-installed **burrowee-edge** relay
against `console.burrowee.com`. The binary must be on PATH — if not, route to
`burrowee-edge-install` and stop.

This skill **requires interactive operator steps** (portal mint, explicit approve,
service-vs-foreground choice). Pause and ask; resume on confirmation.

The edge is **hard-bound to `console.burrowee.com`** — there is no console-selection
flag. If the operator needs a different console, that is a different (dev) build.

The slim `burrowee-edge` binary runs only the service (`version` / `run` / `update`);
every setup/operator command below is `burrowee edge cli <command>` (the companion
`burrowee-edge-cli`, installed alongside and routed through the `burrowee` dispatcher).

## 0. Pre-flight

```bash
burrowee-edge version
ls -ld "$HOME/.burrowee/edge" 2>/dev/null || echo "no ~/.burrowee/edge dir"
```

`burrowee-edge version` must print a real version line (else → burrowee-edge-install).
If `$HOME/.burrowee/edge` already holds an identity from a prior pairing, ask the
operator: keep that identity (just re-pair/refresh) or wipe and start over.

---

## 1. Mint the edge in the portal (operator step)

Tell the operator:

> Open `https://console.burrowee.com`, go to **Edge relays → Add edge relay**, enter
> the public hostname this box will serve on (its `hostname_base`), and copy the
> **blob** and **PIN** it shows. Paste both back here.

Wait for the blob + PIN. (Backend: `POST /api/v1/relays {hostname_base}` →
`{relay_id, blob, pin}`, owner-tier — spec §4 ①, §7. The blob is self-contained:
its header carries `console_url`, `console_pub` and the scrypt salt, so blob + PIN
is everything the edge needs.)

---

## 2. Bootstrap

```bash
burrowee edge cli bootstrap <blob> <pin>
```

This generates the edge's Ed25519 identity (private key never leaves the box),
recovers `console_url`/`console_pub`/`salt` from the blob header (the PIN
authenticates them via the AEAD AAD), decodes the enroll secret, and runs the
one-shot enroll handshake against `console.burrowee.com`. On success it prints the
edge **fingerprint** and `awaiting approval`, and persists the console identity into
`$HOME/.burrowee/edge` so later `run` needs no env. Record the fingerprint — the
operator approves *that exact* fingerprint next. (Backend: the one-shot enroll
handshake presents the self-pubkey + sealed secret; the **console** binds the pubkey
to the pending row, then the identity handshake loops on `relay-pending` — spec §4 ②.)

---

## 3. Approve (operator step)

Tell the operator:

> Back in `console.burrowee.com → Edge relays`, find the pending edge with fingerprint
> `<fingerprint from step 2>` and click **Approve**.

`status` reflects approval by what it prints: before the console pushes the
signed config it prints `enrolled; no config received yet (...)`; once approved
and connected it prints the signed-config dump (`owner tenant:`, `served domains:`,
`max gateways:`, …). Note: the signed config arrives over the carrier, so the edge
must be running (`burrowee-edge run`, or the managed service from §4) for the config
to land — run `status` again after the run loop reports the carrier connected.

```bash
burrowee edge cli status    # repeat until it prints the signed-config dump
                            # (owner tenant / served domains), not "no config yet"
```

You can also confirm console reachability directly with
`burrowee edge cli doctor` (the `console reachable` line). (Backend:
`GET /api/v1/relays/pending` + `POST /api/v1/relays/{id}/approve`, owner-owns
check — spec §4 ③.) Do not proceed until `status` prints the signed-config dump.

---

## 4. Run: managed service vs foreground

Ask the operator; don't pick for them.

**Option A — managed service (recommended for an always-on VPS):**

```bash
burrowee edge cli service install
burrowee edge cli service status    # confirm loaded/started
```

Writes the launchd plist (macOS) / systemd unit (Linux) and bootstraps it; the
edge survives reboot.

**Option B — foreground (recommended for first-run / debugging):**

> Open a separate terminal and run `burrowee-edge run`. Leave it running; switch
> back when you see the carrier connect to `console.burrowee.com`.

Do **not** background `burrowee-edge run` from this skill's shell — its logs are the
operator's primary debugging surface. Wait for the operator to confirm it's up.

---

## 5. nginx fronting (automatic default)

nginx fronting is the **unconditional default** for every new edge install. Two
sub-topologies exist:

- **LAN-only** — no public domain planned. nginx external port **8448** terminates
  TLS with a locally-generated 10-year self-signed cert, then proxies raw TCP to the
  edge at `127.0.0.1:9448`. The LAN port serves **wss** — gateways and CLIs verify
  by pinned cert fingerprint (synced via endpoint reports); no CA or browser trust is
  implied. The edge sets `tls_listen=off`.
- **Domain-fronted** — a custom domain is planned (or already attached). nginx also
  listens on **443** → edge `127.0.0.1:9443` (TCP passthrough; TLS terminates inside
  the edge via console-pushed SNI certs) in addition to the LAN wss pair above.

> **Exception — direct bind:** skip this section only if the edge process will own
> external ports directly (e.g. a container or VM where it is the sole listener and
> privileged port binding is not a concern). This is the unusual case; follow the
> nginx path by default.

> QUIC (UDP), if enabled via `quic_addr`, is not fronted — it stays direct.

**5a. Stand up the front — `burrowee edge cli doctor --fix` (the one command)**

A single command brings the whole LAN front up: it installs nginx if missing
(prompting for consent first), generates the 10-year LAN cert, writes + loads the
nginx front config, starts nginx as a managed service, then re-checks that the
advertised LAN port is reachable. It replaces the manual install + apply + start
(the breakdown in 5b–5f):

```bash
# macOS (Homebrew — no sudo needed):
burrowee edge cli doctor --fix

# Linux (the nginx install + `systemctl enable` need root; --home points the
# front config + cert back at the service user's edge dir, since sudo swaps $HOME):
sudo "$(command -v burrowee-edge-cli)" doctor --fix --home "$HOME/.burrowee/edge"

# Unattended (CI / scripted) — assume yes for the install/start prompts:
sudo "$(command -v burrowee-edge-cli)" doctor --fix --yes --home "$HOME/.burrowee/edge"
```

`burrowee edge cli doctor` (without `--fix`) is the **read-only** check — it prints
nginx installed / running / front config / **LAN front reachable**, so you can
confirm the front before and after. For the **domain-fronted** topology, write the
config (5c) first so the `:443` passthrough block is emitted. The steps below
(5b–5f) are what `--fix` automates — follow them by hand only for non-default ports
(`doctor --fix` uses the standard 8448) or to understand each step.

**5b. Port availability check**

Before writing any config, verify that the required ports are free:

```bash
# Always check (LAN pair):
nc -z 127.0.0.1 8448 && echo "8448 TAKEN" || echo "8448 free"
nc -z 127.0.0.1 9448 && echo "9448 TAKEN" || echo "9448 free"

# Additionally when a domain is planned (domain-fronted only):
nc -z 127.0.0.1 443  && echo "443 TAKEN"  || echo "443 free"
nc -z 127.0.0.1 9443 && echo "9443 TAKEN" || echo "9443 free"
```

If **any** required port is taken, **stop and ask the operator to choose both
replacement ports** — one external port for nginx and one localhost port for the
edge — and use that chosen pair in every step below. (The `burrowee edge cli nginx`
subcommand also pre-flights ports and will name the right flag
(`--listen-lan`/`--listen-tls`) if anything slips through.)

**5c. Write the edge config**

Write `~/.burrowee/edge/config` with the appropriate block:

*LAN-only (no domain planned):*
```
tls_listen=off
lan_listen=127.0.0.1:9448
```

*Domain-fronted (custom domain planned):*
```
tls_listen=127.0.0.1:9443
lan_listen=127.0.0.1:9448
```

`lan_advertise_port=8448` is **not** set here — the `nginx` subcommand persists it
automatically into the config. If the host has noisy interfaces and you want to
restrict LAN connections to a specific IP, add `lan_allow_ips=10.10.101.100`
(comma-separated positive allowlist).

The edge now binds only loopback; nginx owns the external ports (`:443` for
domain-fronted, `:8448` for LAN).

**5d. Apply: generate the LAN cert + install the nginx config**

```bash
sudo "$(command -v burrowee-edge-cli)" nginx --home "$HOME/.burrowee/edge" --listen-lan 8448
```

This single command does everything: generates the 10-year LAN cert at
`~/.burrowee/edge/lan-cert/` when absent, writes
`burrowee-edge-stream.conf` into the nginx conf dir (`/etc/nginx` on Linux,
`/opt/homebrew/etc/nginx` on macOS), persists `lan_advertise_port` and `lan_cert`
into the config automatically, verifies nginx loads the file, runs `nginx -t`, and
reloads. Apply is the default — `--write`/`--reload` are deprecated no-op aliases.
Use `--print` to preview the config without writing anything.

`--home` is required: `sudo` replaces `$HOME` with root's, so the flag points the
subcommand back at the service user's edge directory.

The subcommand defaults `--listen-lan` to **8448** (the standard LAN port). Pass a
different value only when you chose a replacement port in step 5b.

For domain-fronted installs the command is identical — the `:443` passthrough block
is emitted automatically because the config has `tls_listen=127.0.0.1:9443`
rather than `off`.

When the command succeeds it prints the **LAN cert fingerprint** and confirms the
pin reaches gateways and CLIs automatically via the next endpoint report — no manual
distribution needed.

**5e. If the subcommand reports the config is not loaded**

`burrowee edge cli nginx` auto-manages a top-level `stream {}` block in `nginx.conf`
itself; it normally needs no manual edit. If its heuristic can't place the block
(an unusual `nginx.conf` layout), it prints:

```
<conf-dir>/servers-stream/burrowee-edge-stream.conf is NOT loaded by nginx.
This command auto-manages a top-level stream block in <conf-dir>/nginx.conf:

    stream {
        include servers-stream/*.conf;
    }

If the file is still not loaded, confirm that block is present at the TOP
LEVEL of nginx.conf (outside http{}) and that nginx was built with the stream
module (nginx -V should list --with-stream), then re-run.
```

Add that `stream { include servers-stream/*.conf; }` block to `nginx.conf`
**outside** any `http {}` block, confirm `nginx -V` lists `--with-stream`, then
re-run the command. This is the classic conf.d-only trap: many distros auto-include
`conf.d/*.conf` from *inside* `http {}`, where a `stream {}` block is silently
dead — the block must sit at the top level.

**5f. Restart the edge service and verify**

```bash
# restart
# Linux (user unit):
systemctl --user restart burrowee-edge.service
# macOS (launchd):
launchctl kickstart -k gui/$(id -u)/org.burrowee.edge
# Fallback — re-install the unit file (first-time or after binary move):
burrowee edge cli service install

# verify: nginx owns + forwards the LAN port (TCP reachable)
nc -z 127.0.0.1 8448

# confirm the self-signed LAN cert is served:
openssl s_client -connect 127.0.0.1:8448 </dev/null 2>/dev/null | head -3
```

A "verify error" from openssl is **expected** — the LAN cert is self-signed; clients
authenticate it by pinned fingerprint, not by a CA chain.

The LAN port probe (`127.0.0.1:8448`) must succeed for all topologies. For
domain-fronted installs, also probe:

```bash
nc -z 127.0.0.1 443
```

If the LAN port probe is refused entirely, check `nginx -T | grep stream` (the
stream block must appear), and confirm the edge config has the `lan_listen` line
above. For domain-fronted, also check `tls_listen`.

**Cert rotation**

```bash
sudo "$(command -v burrowee-edge-cli)" nginx --home "$HOME/.burrowee/edge" \
    --listen-lan 8448 --rotate-lan-cert
```

`--rotate-lan-cert` mints a new LAN cert and re-applies. Consequence: CLI relay
blobs must be re-pasted (CLIs have no push channel). Gateway clients heal
automatically via the next endpoint report push.

---

## 6. Attach a custom domain

The edge serves **custom domains only**. Tell the operator:

> In `console.burrowee.com → Edge relays → <this edge> → Attach domain`, claim your
> domain for a gateway + service. The portal shows two DNS records. Publish both at
> any DNS host:
> - `<your-domain>`            A/CNAME → this edge's public address
> - `_acme-challenge.<domain>` CNAME  → `<slug>.acme.burrowee.net`

Then poll for the cert:

```bash
burrowee edge cli status    # watch the domain appear under "served domains"
```

(Backend: the `acme.burrowee.net` certbot DNS-01 pipeline issues the LE cert, the
console seals it + pushes it to this edge via `relay/cert/upsert`, and pushes the
`hostname→(gateway_fp, svc)` route via `relay/route/upsert` — spec §9.)

> **Web serving:** the relay's `:443` Host-ingress proxies browser requests to the
> gateway via the core `WebOpen` frame (C0 **W4**, merged 2026-06-04), so custom-domain
> **web viewers** work once the cert + route land — same as raw TCP/SSH. (Edge builds
> from a pre-W4 relay served raw TCP/SSH only.)

---

## 7. Verify

```bash
burrowee edge cli doctor    # every line ✓
```

Confirm the carrier is up (heartbeat), enroll state `active`, the TLS listener up
(`doctor`), and the domain listed under `status`'s served domains. Then confirm
end-to-end through the custom domain —
a raw TCP/SSH connect, or a browser request for a web service (the `:443` W4
web-ingress is live).

---

## 8. Hand back

When green, tell the operator:

> Your edge is paired and serving. Useful commands:
> - `burrowee edge cli status` — enroll state, tenant, served domains, caps
> - `burrowee edge cli doctor` — re-verify any time (`--fix` brings the nginx front up)
> - `burrowee edge cli service restart` — restart the managed service
> - `burrowee-edge update` — install the latest release, then restart the service
>   (`--dry` reports the version gap + changelog only)
> - Service logs (macOS): the launchd agent writes no log file — for log output,
>   stop the service and run `burrowee-edge run` in the foreground
> - Service logs (linux): `journalctl --user -u burrowee-edge.service -f`
>
> Adding more domains/services happens in `console.burrowee.com → Edge relays`.

---

## Troubleshooting hooks

- **"awaiting approval" never flips to active.** The operator approved a *different*
  edge, or is signed into the wrong account. Confirm the fingerprint in the portal
  matches step 2; confirm they're the owner-tier account that minted it.
- **Console unreachable.** The edge dials the console only via its compiled-in
  relay-API host `edge-relay-api.burrowee.org` (no override; the portal stays
  `console.burrowee.com`). Check the VPS's outbound HTTPS/WSS to
  `edge-relay-api.burrowee.org`; honor `HTTPS_PROXY` if behind a proxy.
- **`status` doesn't list the new domain for a while.** DNS propagation + LE issuance
  take time; the `_acme-challenge` CNAME must resolve to `<slug>.acme.burrowee.net`.
  Re-run `status` after a few minutes.
- **Re-pair from scratch.** `rm -rf $HOME/.burrowee/edge` then re-run from step 1.
  This wipes the identity; the console-side pending row must be re-minted.
- **`service install` fails: systemd not available.** Non-systemd init (OpenRC,
  runit) — fall back to Option B (foreground) or a custom supervisor.

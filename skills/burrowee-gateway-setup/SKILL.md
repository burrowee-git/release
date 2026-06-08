---
name: burrowee-gateway-setup
description: Configure and run an installed burrowee gateway — point it at a relay with its Ed25519 key + per-pair PSK, start it, watch the carrier come up on the local console, and optionally register extra named services with burrowee-register. Use after the burrowee gateway is installed (see burrowee-gateway-install). Trigger when the operator says "set up burrowee gateway", "run my gateway", "connect gateway to the relay", or pastes release.burrowee.com/skills/burrowee-gateway-setup/SKILL.md.
---

# burrowee-gateway-setup

You are an LLM coding agent bringing up an already-installed **burrowee gateway**:
the home-NAT tunnel endpoint that dials out to the relay, authenticates its carrier
with the per-pair PSK, and forwards opaque streams to local services. The binaries
must be on PATH — if `burrowee gateway version` fails, route to
`burrowee-gateway-install` and stop.

Both `burrowee gateway …` and the bare `burrowee-gateway …` are the same surface
(the dispatcher just execs the component); likewise `burrowee register …` ==
`burrowee-register …`.

**The gateway is configured by environment variables only** — apart from the
`version` subcommand (install check), it takes no subcommands and no flags. It
starts running the moment it is invoked with no subcommand, so do not launch it
until the required env is in place. `burrowee-register` is the one flag-driven
helper (`-sock`/`-name`/`-target`).

This skill **requires interactive operator inputs**: the relay URL, the gateway's
Ed25519 private key file, and the per-pair PSK file. Pause and ask; resume on
confirmation. Do not invent key material.

---

## 0. Pre-flight

```bash
burrowee gateway version
uname -s
```

`burrowee gateway version` must print a real version line (else →
burrowee-gateway-install).

---

## 1. Gather the required configuration (operator step)

The gateway needs four required values (from the binary's documented env, Doc 4 §7):

| Env var | Meaning |
|---|---|
| `BURROWEE_RELAY_WS` | `ws(s)://` URL of the relay carrier endpoint |
| `BURROWEE_GW_TARGET` | raw-forward fallback dial address (e.g. `127.0.0.1:22`) |
| `BURROWEE_GW_ED_KEY` | path to the gateway Ed25519 **private** key (raw 64 bytes) |
| `BURROWEE_GW_PSK` | path to the per-pair PSK (raw bytes) |

Tell the operator:

> I need four things to run the gateway: the **relay WS URL**, the **local target**
> to forward to (default service, e.g. `127.0.0.1:22` for SSH), and the file paths
> to this gateway's **Ed25519 private key** (raw 64 bytes) and its **per-pair PSK**
> (raw bytes). Provide these from your gateway pairing / dashboard.

Wait for all four. The key + PSK are files the gateway *reads*; this binary does not
generate them. If the operator doesn't have them, they come from the pairing flow on
the dashboard — stop and have them obtain the key + PSK first.

Optional env (mention only if relevant; each has a sane default):

| Env var | Default | Use |
|---|---|---|
| `BURROWEE_GW_SVC_NAME` | `ssh` | name seeded for the fallback target |
| `BURROWEE_GW_REGISTER_SOCK` | `$XDG_RUNTIME_DIR/burrowee/register.sock` (temp-dir fallback) | register socket path |
| `BURROWEE_GW_CONSOLE_ADDR` | `127.0.0.1:16518` | local console listen address (loopback only) |
| `BURROWEE_GW_CONSOLE` | (on) | set to `off` to disable the local console |
| `BURROWEE_GW_DB` | `~/.burrowee/gateway/gateway.db` | ports/sessions store path |
| `BURROWEE_GW_KEYS_DIR` | `~/.burrowee/gateway/keys` | where the session HMAC key is kept |
| `BURROWEE_GW_HOSTNAME` | (empty) | public hostname for share URLs |
| `BURROWEE_GW_ROTATE_AFTER` | `2000000000` | streams before the carrier rotates |
| `BURROWEE_GW_DRAIN_TIMEOUT` | `5m` | drain window for a retiring carrier |

> The session HMAC key is generated and persisted by the gateway itself on first
> run (under `BURROWEE_GW_KEYS_DIR`) — no operator action needed.

---

## 2. Run the gateway

The gateway runs in the foreground and logs to stdout/stderr — that is the
operator's primary debugging surface, so do **not** background it from this skill's
shell. Tell the operator:

> Open a separate terminal, export the four required vars, and run the gateway.
> Switch back when you see the `burrowee-gateway: relay=… register=… fallback=…`
> startup line and (if the console is on) `local console on http://127.0.0.1:16518`.

```bash
export BURROWEE_RELAY_WS="<ws-or-wss-relay-url>"
export BURROWEE_GW_TARGET="127.0.0.1:22"          # your default local service
export BURROWEE_GW_ED_KEY="<path-to-ed25519-private-key>"
export BURROWEE_GW_PSK="<path-to-psk-file>"
burrowee gateway                                   # == burrowee-gateway
```

If a required env var is missing the gateway prints `missing required env <NAME>`
and exits — fill it and re-run. If the key file isn't exactly 64 bytes it exits with
an `ed key: want 64 bytes` error.

---

## 3. Verify the carrier + console

With the gateway running, confirm it connected:

- The log shows the startup line and no repeating `gateway: …` errors.
- If the console is enabled (default), open the loopback UI to watch carrier state:

```bash
curl -fsS http://127.0.0.1:16518/ >/dev/null && echo "console up"
```

(Adjust the address if `BURROWEE_GW_CONSOLE_ADDR` was overridden. The console binds
loopback only.)

Then end-to-end: from a paired client (see the `burrowee-cli-setup` skill) connect
to the gateway's seeded service — e.g. SSH through the relay to the gateway's
`BURROWEE_GW_TARGET`.

---

## 4. (Optional) Register extra named services

The gateway raw-forwards unknown service names to `BURROWEE_GW_TARGET`. To expose an
**additional** named service that bridges to a different local TCP address, run the
`burrowee-register` helper against the gateway's register socket. Real flags only:

```bash
burrowee register \
  -sock   "<register-socket-path>" \
  -name   "<service-name>" \
  -target "<host:port>"
# == burrowee-register -sock … -name … -target …
```

- `-sock` is the gateway's register socket — the same path as
  `BURROWEE_GW_REGISTER_SOCK` (default `$XDG_RUNTIME_DIR/burrowee/register.sock`,
  temp-dir fallback when `XDG_RUNTIME_DIR` is unset).
- `-name` is the service name a client opens (`--svc` on the cli side).
- `-target` is the local `host:port` to bridge each opened stream to.

All three flags are required; with any missing it prints the usage line. On success
it logs `registered "<name>" → <target>`. Leave it running — it serves streams for
that name until stopped.

---

## 5. Hand back

When the carrier is up and a connection works, tell the operator:

> Your gateway is running and serving. Notes:
> - It is configured **only** by environment variables (no subcommands/flags); to
>   change config, stop it, adjust the env, and re-run `burrowee gateway`.
> - Local console (loopback): `http://127.0.0.1:16518` (or your
>   `BURROWEE_GW_CONSOLE_ADDR`).
> - Add named services any time with `burrowee register -sock … -name … -target …`.
> - For an always-on box, run it under your own supervisor (systemd unit / launchd
>   plist) exporting the same env — this binary has no built-in service installer.

---

## Troubleshooting hooks

- **`missing required env <NAME>` on start.** One of the four required vars is
  unset/empty — export it and re-run.
- **`ed key: want 64 bytes, got N`.** `BURROWEE_GW_ED_KEY` must point at the raw
  64-byte Ed25519 private key, not a hex/PEM file.
- **Console won't bind.** A non-loopback `BURROWEE_GW_CONSOLE_ADDR` or a port already
  in use is a hard startup error (the gateway exits). Use a free loopback address, or
  set `BURROWEE_GW_CONSOLE=off` to disable the console.
- **`burrowee register` can't reach the socket.** The gateway must be running first
  (it creates the register socket), and `-sock` must match the gateway's
  `BURROWEE_GW_REGISTER_SOCK` (or its default). Start the gateway, then register.
- **Carrier never connects.** Check the box's outbound WSS to `BURROWEE_RELAY_WS`,
  and confirm the PSK + Ed25519 key belong to the pairing the relay expects.

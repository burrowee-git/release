---
name: burrowee-cli-setup
description: First real use of the burrowee cli — pair against a gateway from the dashboard pairing blob, then open a connection (raw TCP forward or SSH) through the relay. Use after the burrowee cli is installed (see burrowee-cli-install). Trigger when the operator says "set up burrowee cli", "pair burrowee", "connect to my gateway", or pastes release.burrowee.com/skills/burrowee-cli-setup/SKILL.md.
---

# burrowee-cli-setup

You are an LLM coding agent driving the **burrowee cli** for its first real use:
pair against a gateway, then forward or SSH through the relay. The binaries must be
on PATH — if `burrowee cli version` fails, route to `burrowee-cli-install` and stop.

Every command below uses the `burrowee cli <subcommand>` form; the bare
`burrowee-cli <subcommand>` is identical (the dispatcher just execs the component).

This skill **requires interactive operator inputs** — the pairing blob, PIN, and
salt come from the gateway's dashboard, and the relay URL + gateway/service names
are operator-specific. Pause and ask; resume on confirmation. Do not invent these
values.

The cli subcommands are exactly: `version`, `connect`, `ssh`, `pair`, `daemon`,
`relays`. Confirm install with `burrowee cli version` (the bare `burrowee-cli
version` is equivalent).

---

## 0. Pre-flight

```bash
burrowee cli version
ls -l "$HOME/.burrowee" 2>/dev/null || echo "no .burrowee dir yet"
```

`burrowee cli version` must print a real version line (else → burrowee-cli-install).

---

## 1. Collect the pairing material (operator step)

Pairing carries the gateway's public key + the per-pair PSK inside an encrypted
blob; the PIN + salt decrypt it. Tell the operator:

> Open your Burrowee dashboard, start a pairing for the gateway you want to reach,
> and copy the four values it shows: the **blob** (`b3.…`), the **salt** (base64url),
> the 6-digit **PIN**, and the **relay URL** (`ws://…/ws/client` or `wss://…`).
> Paste them back here.

Wait for all four. (The PIN gates a short window — pair promptly.)

---

## 2. Pair

`pair` decrypts the blob with the PIN + salt and writes a `config.json` (default
path from `--config`) carrying the gateway pubkey, PSK, relay URL, and a gateway
id label. Real flags only:

```bash
burrowee cli pair \
  --blob "<b3.…>" \
  --salt "<base64url-salt>" \
  --pin  "<6-digit-pin>" \
  --relay "<ws-or-wss-url>" \
  --gw-id "gw1"
```

- `--blob`, `--salt`, `--pin`, `--relay` are **required**.
- `--gw-id` is an optional label for this config (defaults to `gw1`).
- `--config` overrides the config.json output path (defaults to the cli's default
  config path).

On success it prints `paired: wrote <config-path> (relay "<url>")`. A wrong PIN or
salt fails at decrypt — re-collect from the dashboard and retry. Record the
`<config-path>`; the daemon + relays subcommands read it.

---

## 3. Choose a connection path

The cli offers two real paths. Ask the operator which they want.

### Path A — daemon + relays (a warm, long-running carrier)

`daemon` loads the pairing config, holds a warm relay carrier, and serves the local
transport socket. `relays` talks to that socket.

Start the daemon (leave it running — its stdout is the operator's debugging
surface; do **not** background it from this skill's shell):

> Open a separate terminal and run `burrowee cli daemon`. Switch back when you see
> the `burrowee daemon: socket=… gw=… relays=… default=…` line.

```bash
burrowee cli daemon                 # default config + socket paths
# or pin them explicitly:
burrowee cli daemon --config "<config-path>" --socket "<socket-path>"
```

With the daemon up, list and select relays (real subcommands: `list`, `use <id>`):

```bash
burrowee cli relays list            # `*` marks the current default
burrowee cli relays use "<relay-id>"
```

`relays use` persists the default into the config and updates the running daemon;
if the daemon isn't reachable it still saves to the config and tells you so.

### Path B — one-shot connect / ssh

`connect` and `ssh` open a carrier directly (no daemon). They do **not** read the
pairing `config.json` — they take the gateway pubkey + PSK from files/env and the
relay/gateway/service on the command line. Required flags: `--relay`, `--gw`,
`--svc`; the gateway pubkey + PSK come from `--gw-pub`/`BURROWEE_GW_PUB` and
`--psk`/`BURROWEE_PSK`.

Raw TCP forward (prints the local listen address it bound):

```bash
burrowee cli connect \
  --relay "<ws-or-wss-url>" \
  --gw    "<gateway-id>" \
  --svc   "<service-name>" \
  --local "127.0.0.1:0" \
  --gw-pub "<path-to-gw-ed25519-pubkey-hex>" \
  --psk    "<path-to-psk-file>"
```

- `--local` is the local listen address (default `127.0.0.1:0` — an ephemeral port).
- `--relay-quic <host:port>` optionally enables the QUIC relay path (empty disables).
- `--gw-pub` / `--psk` accept env fallbacks `BURROWEE_GW_PUB` / `BURROWEE_PSK`.

SSH straight through (forces an ephemeral local port, then execs the system `ssh`;
trailing args after the flags pass to `ssh`):

```bash
burrowee cli ssh \
  --relay "<ws-or-wss-url>" \
  --gw    "<gateway-id>" \
  --svc   "<ssh-service-name>" \
  --gw-pub "<path-to-gw-ed25519-pubkey-hex>" \
  --psk    "<path-to-psk-file>" \
  -- <user>@anything   # extra args forwarded to ssh
```

---

## 4. Verify

- **Path A:** the daemon's startup line shows the gw id + relay count, and
  `burrowee cli relays list` returns at least one relay with a `*` default.
- **Path B (connect):** the `listening on 127.0.0.1:<port> → relay … gw=… svc=…`
  line prints, and a client (e.g. `ssh -p <port> localhost`, `curl
  http://127.0.0.1:<port>`) reaches the remote service through the forward.
- **Path B (ssh):** you land in the remote shell.

---

## 5. Hand back

When a connection is up, tell the operator the real surface they have:

> burrowee cli is paired and connected. Subcommands:
> - `burrowee cli pair`   — re-pair from a fresh dashboard blob
> - `burrowee cli daemon` — warm long-running carrier (Path A)
> - `burrowee cli relays list` / `relays use <id>` — inspect/select relays
> - `burrowee cli connect` — one-shot local TCP forward
> - `burrowee cli ssh`     — SSH through the relay
>
> The bare `burrowee-cli …` form works identically.

---

## Troubleshooting hooks

- **`pair` fails to decrypt ("wrong PIN or salt?").** The PIN/salt don't match the
  blob, or the pairing window expired. Re-collect all four values from the
  dashboard and re-run step 2.
- **`connect`/`ssh` error: "--relay, --gw and --svc are required".** One of the
  three is empty — fill all three.
- **`connect`/`ssh` error: "gateway public key required".** Provide `--gw-pub`
  (a file holding the gateway ed25519 public key in hex) or set `BURROWEE_GW_PUB`.
- **`relays use` says the daemon wasn't updated.** It still saved the default to the
  config; start `burrowee cli daemon` (Path A) so the running carrier picks it up.
- **macOS: the daemon socket path.** With no `XDG_RUNTIME_DIR`, the default socket
  falls back under the OS temp dir; pin it with `--socket` if a long temp path is a
  problem.

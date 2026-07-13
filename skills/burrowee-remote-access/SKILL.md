---
name: burrowee-remote-access
description: Set up SSH and VNC remote access to a Burrowee gateway from a paired client — write ssh_config/vnc_config, install the bssh/bvnc shell helpers, and connect. Use when the operator says "set up ssh/vnc access", "remote desktop into my machine", "bvnc", "burrowee vnc", or pastes release.burrowee.com/skills/burrowee-remote-access/SKILL.md.
---

# burrowee-remote-access

You are an LLM coding agent standing up SSH/VNC remote access over a paired
**burrowee cli**: write the two alias config files, install the `bssh`/`bvnc`
shell helpers, then connect. This requires an already-paired cli and an
enrolled gateway with an exposed `ssh` and/or `vnc` target — if `burrowee cli
version` fails or the client isn't paired yet, route to `burrowee-cli-install`
/ `burrowee-cli-setup` and stop.

---

## 0. Pre-flight

```bash
burrowee version
ls ~/.burrowee/cli/config.json 2>/dev/null || echo "not paired yet"
```

`burrowee version` must print a real version line, and `config.json` must
exist (written by `burrowee bootstrap <blob> <pin>` — see `burrowee-cli-setup`)
before continuing.

---

## 1. Write the alias config files

Both files live in `~/.burrowee/cli/` (override with `BURROWEE_HOME`) and
share the same directive style: an OpenSSH-style `Host <alias>` block
carrying burrowee routing as `#@` comments. `#@gateway` defaults to the
`Host` alias itself; `#@relay` pins which relay to route through (omit to
use the client's default relay); `#@service` picks the enrolled service
name to reach on the gateway.

`~/.burrowee/cli/ssh_config` (OpenSSH format — `ssh`'s own keywords like
`User`, `IdentityFile`, `IdentitiesOnly` work too; the cli hands this file to
`ssh -F`):

```
# ~/.burrowee/cli/ssh_config
Host home-mac
    #@gateway jc-mac-mini
    #@relay   seoul-relay
    # #@service ssh   (default when omitted)
    User jc
```

`~/.burrowee/cli/vnc_config` (same directive style; `#@service` defaults to
`vnc`; parsed by a small `awk` block inside `bvnc` itself, not by the Go
cli):

```
# ~/.burrowee/cli/vnc_config
Host home-mac
    #@gateway jc-mac-mini
    #@relay   seoul-relay
    # #@service vnc   (default when omitted)
```

A `Host` alias with no matching block is treated as a bare gateway id/name
(`svc=ssh` for `bssh` via the cli's own `ssh_config` handling; `svc=vnc` for
`bvnc`).

---

## 2. Install the shell helper

Canonical snippets ship in the cli distribution's `shell/` directory —
`burrowee.bash`, `burrowee.zsh`, `burrowee.fish` — each defining both `bssh`
and `bvnc` (full bodies are in that directory and rendered live at the ai
`/access` page; this skill doesn't re-host them). Source the file matching
the operator's shell from their rc:

```sh
# bash → ~/.bashrc
source /path/to/burrowee.bash
# zsh → ~/.zshrc
source /path/to/burrowee.zsh
# fish → ~/.config/fish/config.fish
source /path/to/burrowee.fish
```

Confirm both functions loaded: `type bssh bvnc` (bash/zsh) or `functions -q
bssh; and functions -q bvnc` (fish).

---

## 3. Connect

```sh
bssh home-mac          # ssh, via ~/.burrowee/cli/ssh_config
bvnc home-mac          # VNC, via ~/.burrowee/cli/vnc_config
```

`bssh` is a thin wrapper over `burrowee ssh <host>`, which resolves
`ssh_config` and execs the system `ssh` against the forwarded port. `bvnc`
resolves `vnc_config`, opens a `burrowee connect --svc vnc` forward in the
background, launches the platform VNC client, and holds the forward in the
foreground until Ctrl-C — macOS `open` returns immediately (Screen Sharing
detaches), so it's `bvnc` blocking, not the client; that's expected.

Raw equivalents, if you want to see (or bypass) what the helpers do:

```sh
burrowee ssh home-mac
burrowee connect --svc vnc --gw jc-mac-mini --relay seoul-relay --local 127.0.0.1:0
```

`burrowee connect` prints `listening on 127.0.0.1:<port> → relay … gw=… svc=…`
and blocks until SIGINT/SIGTERM, then tears the forward down.

---

## 4. Verify

- **`bssh <host>`** lands in the remote shell.
- **`bvnc <host>`** prints `bvnc: <host> → 127.0.0.1:<port> (svc=vnc gw=…
  relay=…); Ctrl-C to disconnect` and opens a working screen-sharing session.

---

## Troubleshooting hooks

- **No VNC client found.** `bvnc` tries `open` (macOS), then
  `$BURROWEE_VNC_CLIENT`, then `vinagre`/`remmina`/`vncviewer` on Linux. Set
  `BURROWEE_VNC_CLIENT=/path/to/your/viewer` if none of those match, or
  connect manually to the printed `127.0.0.1:<port>` address.
- **Forward never comes up (timeout).** Both helpers poll the `burrowee
  connect` output for up to 10s (100 × 0.1s); if no `listening on …` line
  appears they print the captured output and exit non-zero. Confirm the
  gateway is online and the named service (`ssh`/`vnc`) is actually enrolled
  on it — `burrowee cli relays list` or the dashboard's routes view.
- **Wrong relay picked.** `#@relay` in `ssh_config`/`vnc_config` pins the
  route for that `Host` alias; omit it to fall back to the client's default
  relay, or add/correct the line if a gateway is reachable through more than
  one relay and the wrong one gets picked. `burrowee ssh` also accepts a
  `<host>@<relay>` override to force a specific relay for a one-off connection,
  and `#@relay` in the config records the preferred one.
- **macOS: Screen Sharing seems to "close" right away.** It didn't — `open
  vnc://…` just returns immediately to the shell. The forward is still up in
  the terminal running `bvnc`; leave it running and Ctrl-C there when done.

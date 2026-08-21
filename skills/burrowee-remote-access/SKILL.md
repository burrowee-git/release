---
name: burrowee-remote-access
description: Set up SSH and VNC remote access to a Burrowee gateway from a paired client — write ssh_config/vnc_config, then connect with `burrowee ssh` and `burrowee open`. Use when the operator says "set up ssh/vnc access", "remote desktop into my machine", "burrowee vnc", "burrowee ssh config", or pastes release.burrowee.com/skills/burrowee-remote-access/SKILL.md (legacy phrases: "bssh", "bvnc").
---

# burrowee-remote-access

You are an LLM coding agent standing up SSH/VNC remote access over a paired
**burrowee cli**: write the alias config files, then connect — `burrowee ssh`
for SSH (no wrapper needed), `burrowee open` for VNC and any other service.
This requires an already-paired cli and an enrolled gateway with an exposed
`ssh` and/or `vnc` target — if `burrowee version` fails or the client isn't
paired yet, route to `burrowee-cli-install` / `burrowee-cli-setup` and stop.

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

Each service gets a **`{svc}_config`** alias file in `~/.burrowee/cli/`
(override with `BURROWEE_HOME`), all sharing the same style: an OpenSSH
`Host <alias>` block carrying burrowee routing as `#@` comments. `#@gateway`
defaults to the `Host` alias itself; `#@relay` pins which relay to route
through (repeatable — file order is priority; omit to use the client's
default relay); `#@service` picks the enrolled service name to reach on the
gateway.

`~/.burrowee/cli/ssh_config` (OpenSSH format — `ssh`'s own keywords like
`User`, `IdentityFile`, `IdentitiesOnly` work too; the cli hands this file to
`ssh -F`):

```
# ~/.burrowee/cli/ssh_config
Host home-mac
    #@gateway studio-mini
    #@relay   eu-relay
    # #@service ssh   (default when omitted)
    User sam
```

`~/.burrowee/cli/vnc_config` (same directive style; `#@service` defaults to
the `--svc` value, i.e. `vnc` — and the same shape works for any other
service: `rdp_config`, `http_config`, …):

```
# ~/.burrowee/cli/vnc_config
Host home-mac
    #@gateway studio-mini
    #@relay   eu-relay
    # #@service vnc   (default when omitted)
```

A `<host>` with no matching `Host` block is treated as a bare gateway id/name,
exactly as `ssh <host>` does. `burrowee ssh list` prints the aliases
configured in `ssh_config`.

---

## 2. Connect — SSH

SSH needs no wrapper at all:

```sh
burrowee ssh home-mac                  # resolve via ssh_config, forward, exec ssh
burrowee ssh home-mac@eu-relay      # one-off relay override
burrowee ssh home-mac -l me uptime     # everything after <host> passes to ssh VERBATIM
```

`burrowee ssh <host>` resolves `<host>` from `~/.burrowee/cli/ssh_config`,
brings up the forward, and execs the system `ssh` against the forwarded port.
Every token after the host is handed to `ssh` verbatim (`-l me`, `-i key`, a
remote command) — including flags the cli would otherwise read as its own.

---

## 3. Connect — VNC (and any other service)

For non-SSH services, `burrowee open` does the config-driven forward:

```sh
burrowee open --svc vnc home-mac       # resolve via vnc_config, forward the port
```

It prints `listening on 127.0.0.1:<port> → relay … gw=… svc=…`, holds the
forward in the foreground until Ctrl-C, then tears it down. `open` execs no
client of its own — point your viewer at the printed `127.0.0.1:<port>`.

To auto-launch a viewer, the cli distribution ships **example shell
functions** — `shell/burrowee.bash`, `shell/burrowee.zsh`,
`shell/burrowee.fish` (see `shell/README.md` there). They are examples to
copy/adapt into the operator's shell rc, not shipped commands. Each defines a
`vnc` function that wraps `burrowee open --svc vnc <host>`, waits for the
`listening on …` line, launches the platform viewer (macOS `open vnc://…`;
Linux `$BURROWEE_VNC_CLIENT`, else `vinagre`/`remmina`/`vncviewer`), and
holds the forward until Ctrl-C:

```sh
# bash → ~/.bashrc          source /path/to/burrowee.bash
# zsh  → ~/.zshrc           source /path/to/burrowee.zsh
# fish → ~/.config/fish/config.fish    source /path/to/burrowee.fish

vnc home-mac    # burrowee open --svc vnc home-mac + launch a viewer; Ctrl-C to disconnect
```

Adapt the same function for any `{svc}_config` service (`rdp`, `http`, …).

---

## 4. Verify

- **`burrowee ssh <host>`** lands in the remote shell.
- **`burrowee open --svc vnc <host>`** prints the `listening on
  127.0.0.1:<port> …` line and keeps running; a viewer pointed at that
  address opens a working screen-sharing session.

---

## Troubleshooting hooks

- **No VNC client found.** The example `vnc` function tries `open` (macOS),
  then `$BURROWEE_VNC_CLIENT`, then `vinagre`/`remmina`/`vncviewer` on Linux.
  Set `BURROWEE_VNC_CLIENT=/path/to/your/viewer` if none of those match, or
  skip the function and connect any viewer manually to the `127.0.0.1:<port>`
  address `burrowee open` prints.
- **Forward never comes up.** Confirm the gateway is online and the named
  service (`ssh`/`vnc`) is actually enrolled on it — `burrowee relays list`
  shows the configured relays, and the dashboard's routes view shows what
  each gateway exposes.
- **Wrong relay picked.** `#@relay` in the `{svc}_config` pins the route for
  that `Host` alias; omit it to fall back to the client's default relay, or
  add/correct the line if a gateway is reachable through more than one relay.
  Both `burrowee ssh` and `burrowee open` also accept a `<host>@<relay>`
  override to force a specific relay for a one-off connection.
- **macOS: Screen Sharing seems to "close" right away.** It didn't — `open
  vnc://…` just returns immediately to the shell. The forward is still up in
  the terminal running `burrowee open` (or the `vnc` function); leave it
  running and Ctrl-C there when done.

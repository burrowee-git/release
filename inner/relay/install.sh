#!/bin/sh
# Burrowee inner installer — relay (POSIX sh, macOS + Linux).
#
# Ships at the ROOT of the verified release zip as `install.sh`. The outer
# bootstrap verifies the zip (minisign + sha256) and ONLY THEN execs this with
# cwd = the unzipped dir, so the binaries sit alongside this script.
#
# ROOT-AWARE: when run as root (`curl ... | sudo sh`, the console-minted system
# install), it installs the binary to /usr/local/bin and sets up a MANAGED ROOT
# SERVICE — a systemd system unit on Linux, a launchd LaunchDaemon on macOS —
# then enables + (re)starts it. When run unprivileged it keeps the historical
# behavior: a user-path binary drop under $HOME/.local/bin with no service, plus
# a note that a managed system service needs sudo.
#
# The system unit mirrors the canonical production unit from relay/install.sh
# (Description / ExecStart / Restart / WantedBy / HOME) so a console-minted root
# install is byte-identical to what the production updater daemon would write.
#
# Idempotent: re-running replaces the binary + unit and restarts the service, so
# the same one-liner serves both fresh installs and in-place updates.
#
# NOTE: the relay updater unit (burrowee-relay-updater) is OUT OF SCOPE here and
# is set up separately — this installer manages only the main burrowee-relay
# service.
#
# Note: relay bootstrap is invoked as `burrowee-relay bootstrap <blob> <pin>`
# by the operator — this installer does NOT run interactive setup.
set -eu

BINS="burrowee-relay"

# ── system (root) install paths ──────────────────────────────────────────────
SYS_BIN_DIR="/usr/local/bin"
SYSTEMD_UNIT="/etc/systemd/system/burrowee-relay.service"
LAUNCHD_PLIST="/Library/LaunchDaemons/org.burrowee.relay.plist"
LAUNCHD_LABEL="org.burrowee.relay"

is_root() { [ "$(id -u)" = 0 ]; }

# place_bin SRC DST — install a 0755 binary and strip the macOS quarantine xattr.
place_bin() {
    install -m 0755 "$1" "$2"
    if [ "$(uname -s)" = "Darwin" ]; then
        xattr -d com.apple.quarantine "$2" 2>/dev/null || true
    fi
}

# ── uninstall (honors the same root/non-root split) ──────────────────────────
if [ -n "${BURROWEE_UNINSTALL:-}" ]; then
    if is_root; then
        if [ "$(uname -s)" = "Darwin" ]; then
            launchctl bootout "system/$LAUNCHD_LABEL" 2>/dev/null || true
            rm -f "$LAUNCHD_PLIST"
        else
            systemctl disable --now burrowee-relay 2>/dev/null || true
            rm -f "$SYSTEMD_UNIT"
            systemctl daemon-reload 2>/dev/null || true
        fi
        for b in $BINS; do rm -f "$SYS_BIN_DIR/$b"; done
        rm -f "$SYS_BIN_DIR/burrowee"
        echo "removed system service + binaries from $SYS_BIN_DIR: $BINS"
    else
        BIN_DIR="${PREFIX:-$HOME/.local}/bin"
        for b in $BINS; do rm -f "$BIN_DIR/$b"; done
        echo "removed from $BIN_DIR: $BINS"
    fi
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# NON-ROOT — historical behavior: user-path binary drop, no service.
# ─────────────────────────────────────────────────────────────────────────────
if ! is_root; then
    BIN_DIR="${PREFIX:-$HOME/.local}/bin"
    mkdir -p "$BIN_DIR"
    for b in $BINS; do
        [ -f "./$b" ] || { echo "missing $b in archive" >&2; exit 1; }
        place_bin "./$b" "$BIN_DIR/$b"
    done
    echo "installed to $BIN_DIR: $BINS"

    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) echo "note: $BIN_DIR is not on PATH — add: export PATH=\"$BIN_DIR:\$PATH\"" ;;
    esac

    echo "note: installed to $BIN_DIR (user path, no managed service);"
    echo "      for a managed system service re-run with sudo."

    "$BIN_DIR/burrowee-relay" --version 2>/dev/null || true
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# ROOT — system install: /usr/local/bin + managed root service.
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "$SYS_BIN_DIR"
for b in $BINS; do
    [ -f "./$b" ] || { echo "missing $b in archive" >&2; exit 1; }
    place_bin "./$b" "$SYS_BIN_DIR/$b"
done
# Ship the universal dispatcher too when the zip bundles it (relay zips do not
# today, but stay forward-compatible if it is ever added).
if [ -f "./burrowee" ]; then
    place_bin "./burrowee" "$SYS_BIN_DIR/burrowee"
fi
echo "installed to $SYS_BIN_DIR: $BINS"

if [ "$(uname -s)" = "Darwin" ]; then
    # ── macOS: root LaunchDaemon ──────────────────────────────────────────────
    cat > "$LAUNCHD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LAUNCHD_LABEL</string>
  <key>ProgramArguments</key><array><string>$SYS_BIN_DIR/burrowee-relay</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>2</integer>
</dict></plist>
EOF
    chmod 0644 "$LAUNCHD_PLIST"
    echo "wrote LaunchDaemon → $LAUNCHD_PLIST"
    # Reload idempotently: bootout the old job (ignore "not loaded"), then bootstrap.
    launchctl bootout "system/$LAUNCHD_LABEL" 2>/dev/null || true
    launchctl bootstrap system "$LAUNCHD_PLIST"
    launchctl enable "system/$LAUNCHD_LABEL"
    # bootstrap already started it (RunAtLoad); kickstart -k forces a clean restart
    # on a re-run/update so the new binary is the live one.
    launchctl kickstart -k "system/$LAUNCHD_LABEL" 2>/dev/null || true
    echo "launchd service $LAUNCHD_LABEL enabled + started"
else
    # ── Linux: systemd system unit (canonical — mirrors relay/install.sh) ─────
    # systemd exports no HOME without User=; the daemon's config home is
    # ~/.burrowee/relay via os.UserHomeDir(), so HOME must be set explicitly or it
    # aborts "resolve home: cannot determine home dir". A root system service has
    # HOME=/root.
    mkdir -p "$(dirname "$SYSTEMD_UNIT")"
    cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=burrowee relay (blind forwarder)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=/root
ExecStart=$SYS_BIN_DIR/burrowee-relay
Restart=on-failure
RestartSec=2
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$SYSTEMD_UNIT"
    echo "wrote systemd unit → $SYSTEMD_UNIT"
    systemctl daemon-reload
    systemctl enable --now burrowee-relay
    # Force a restart on re-run/update so the freshly placed binary is live.
    systemctl restart burrowee-relay
    echo "systemd service burrowee-relay enabled + (re)started"
fi

"$SYS_BIN_DIR/burrowee-relay" --version 2>/dev/null || true
echo "relay system install complete."

#!/bin/sh
# Burrowee inner installer — gateway (POSIX sh).
#
# Ships at the ROOT of the verified release zip as `install.sh`. The outer
# bootstrap verifies the zip (minisign + sha256) and ONLY THEN execs this with
# cwd = the unzipped dir, so the binaries sit alongside this script. It installs
# them into PREFIX/bin (default $HOME/.local/bin). Set BURROWEE_UNINSTALL to
# remove them instead. Set BURROWEE_UNITS_ONLY=1 to write+load both service
# units without touching binaries or running bootstrap.
set -eu

BIN_DIR="${PREFIX:-$HOME/.local}/bin"
BINS="burrowee burrowee-gateway burrowee-gateway-cli burrowee-gateway-console burrowee-register"
COMP=gateway
GW_HOME="$HOME/.burrowee/gateway"

# ---------------------------------------------------------------------------
# write_units — render + load both service units for the host init system.
# ---------------------------------------------------------------------------
write_units() {
    case "$(uname -s)" in
    Darwin)
        _la_dir="$HOME/Library/LaunchAgents"
        _log_dir="$GW_HOME/logs"
        mkdir -p "$_la_dir" "$_log_dir"

        # Migrate pre-rename installs: bootout the stale org.burrowee.gateway agent.
        launchctl bootout "gui/$(id -u)/org.burrowee.gateway" 2>/dev/null || true
        rm -f "$HOME/Library/LaunchAgents/org.burrowee.gateway.plist"

        # Core unit.
        _core_plist="$_la_dir/com.burrowee.gateway.plist"
        cat > "$_core_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.burrowee.gateway</string>
  <key>ProgramArguments</key><array><string>$BIN_DIR/burrowee-gateway</string><string>--no-open</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$GW_HOME/logs/gateway.log</string>
  <key>StandardErrorPath</key><string>$GW_HOME/logs/gateway.err.log</string>
</dict></plist>
EOF
        launchctl bootout "gui/$(id -u)/com.burrowee.gateway" 2>/dev/null || true
        launchctl bootstrap "gui/$(id -u)" "$_core_plist"
        echo "service unit: $_core_plist"

        # Updater unit.
        _upd_plist="$_la_dir/com.burrowee.gateway.updater.plist"
        cat > "$_upd_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.burrowee.gateway.updater</string>
  <key>ProgramArguments</key><array><string>$BIN_DIR/burrowee-gateway-cli</string><string>updater</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$GW_HOME/logs/updater.log</string>
  <key>StandardErrorPath</key><string>$GW_HOME/logs/updater.err.log</string>
</dict></plist>
EOF
        launchctl bootout "gui/$(id -u)/com.burrowee.gateway.updater" 2>/dev/null || true
        launchctl bootstrap "gui/$(id -u)" "$_upd_plist"
        echo "service unit: $_upd_plist"
        ;;

    Linux)
        _sd_dir="$HOME/.config/systemd/user"
        mkdir -p "$_sd_dir" "$GW_HOME/logs"

        # Core unit.
        _core_svc="$_sd_dir/burrowee-gateway.service"
        cat > "$_core_svc" <<EOF
[Unit]
Description=burrowee-gateway
After=network-online.target

[Service]
ExecStart=$BIN_DIR/burrowee-gateway --no-open
Restart=on-failure
RestartSec=2
TimeoutStopSec=330

[Install]
WantedBy=default.target
EOF
        systemctl --user daemon-reload
        systemctl --user enable --now burrowee-gateway.service
        echo "service unit: $_core_svc"

        # Updater unit.
        _upd_svc="$_sd_dir/burrowee-gateway-updater.service"
        cat > "$_upd_svc" <<EOF
[Unit]
Description=burrowee-gateway updater
After=network-online.target

[Service]
ExecStart=$BIN_DIR/burrowee-gateway-cli updater
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF
        systemctl --user enable --now burrowee-gateway-updater.service
        echo "service unit: $_upd_svc"
        ;;

    *)
        echo "warning: unsupported OS — skipping service unit installation" >&2
        ;;
    esac
}

# ---------------------------------------------------------------------------
# Mode dispatch.
# ---------------------------------------------------------------------------

if [ -n "${BURROWEE_UNITS_ONLY:-}" ]; then
    write_units
    exit 0
fi

if [ -n "${BURROWEE_UNINSTALL:-}" ]; then
    for b in $BINS; do rm -f "$BIN_DIR/$b"; done
    echo "removed from $BIN_DIR: $BINS"

    # Remove service units.
    case "$(uname -s)" in
    Darwin)
        launchctl bootout "gui/$(id -u)/com.burrowee.gateway" 2>/dev/null || true
        launchctl bootout "gui/$(id -u)/com.burrowee.gateway.updater" 2>/dev/null || true
        rm -f "$HOME/Library/LaunchAgents/com.burrowee.gateway.plist"
        rm -f "$HOME/Library/LaunchAgents/com.burrowee.gateway.updater.plist"
        ;;
    Linux)
        systemctl --user disable --now burrowee-gateway.service 2>/dev/null || true
        systemctl --user disable --now burrowee-gateway-updater.service 2>/dev/null || true
        rm -f "$HOME/.config/systemd/user/burrowee-gateway.service"
        rm -f "$HOME/.config/systemd/user/burrowee-gateway-updater.service"
        ;;
    esac

    exit 0
fi

# ---------------------------------------------------------------------------
# Fresh install (default mode).
# ---------------------------------------------------------------------------
mkdir -p "$BIN_DIR"
for b in $BINS; do
    [ -f "./$b" ] || { echo "missing $b in archive" >&2; exit 1; }
    install -m 0755 "./$b" "$BIN_DIR/$b"
    if [ "$(uname -s)" = "Darwin" ]; then
        xattr -d com.apple.quarantine "$BIN_DIR/$b" 2>/dev/null || true
    fi
done
echo "installed to $BIN_DIR: $BINS"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "note: $BIN_DIR is not on PATH — add: export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

"$BIN_DIR/burrowee" --version 2>/dev/null || true

# Self-copy: keep a copy of this installer at $GW_HOME/install.sh so subsequent
# `service install` verbs can re-render + reload units without a new download.
mkdir -p "$GW_HOME"
cp "$0" "$GW_HOME/install.sh" 2>/dev/null || true

# Write and load both service units.
write_units

# ---- first-run bootstrap (interactive only, fresh installs) -------------------
# Re-install short-circuit: if this component already has persisted state under
# ~/.burrowee/<comp> (the gateway db/keys, cli/edge identity, …) it is already
# set up — never re-prompt for a setup blob. Otherwise read blob+PIN from the
# controlling terminal (stdin is the curl pipe, not a tty): prompt only if
# /dev/tty is genuinely usable (fd 3); if not (CI / detached) just print the
# next step. All tty I/O is fault-tolerant so it can never abort the install.
COMP_HOME="$HOME/.burrowee/$COMP"
if [ -d "$COMP_HOME" ] && [ -n "$(ls -A "$COMP_HOME" 2>/dev/null || true)" ]; then
    echo "$COMP already set up ($COMP_HOME) — skipping setup."
elif { exec 3<>/dev/tty; } 2>/dev/null; then
    printf '\nSet up now? Paste the setup blob + PIN from the console (Enter to skip).\n' >&3 2>/dev/null || true
    printf 'blob> ' >&3 2>/dev/null || true
    blob=''; IFS= read -r blob <&3 2>/dev/null || blob=''
    if [ -n "$blob" ]; then
        printf 'pin>  ' >&3 2>/dev/null || true
        pin=''; IFS= read -r pin <&3 2>/dev/null || pin=''
        if [ -n "$pin" ]; then
            "$BIN_DIR/burrowee" "$COMP" bootstrap "$blob" "$pin" <&3 || true
        else
            printf 'No PIN — skipped. Run later: burrowee %s bootstrap <blob> <pin>\n' "$COMP" >&3 2>/dev/null || true
        fi
    else
        printf 'Skipped. Run later: burrowee %s bootstrap <blob> <pin>\n' "$COMP" >&3 2>/dev/null || true
    fi
    exec 3>&- 2>/dev/null || true
else
    echo "next: burrowee $COMP bootstrap <blob> <pin>"
fi

#!/bin/sh
# Burrowee inner installer — gateway (POSIX sh).
#
# Ships at the ROOT of the verified release zip as `install.sh`. The outer
# bootstrap verifies the zip (minisign + sha256) and ONLY THEN execs this with
# cwd = the unzipped dir, so the binaries sit alongside this script. It installs
# them into PREFIX/bin (default $HOME/.local/bin). Set BURROWEE_UNINSTALL to
# remove them instead. Set BURROWEE_UNITS_ONLY=1 to write+load both service
# units without touching binaries or running bootstrap. Set BURROWEE_UPDATE=1
# to run update mode: per-binary sha256 change detection, transactional swap,
# and a final BURROWEE_CHANGED=<names> line.
set -eu

BIN_DIR="${PREFIX:-$HOME/.local}/bin"
BINS="burrowee burrowee-gateway burrowee-gateway-cli burrowee-gateway-console burrowee-register burrowee-gateway-updater"
COMP=gateway
GW_HOME="$HOME/.burrowee/gateway"

# ---------------------------------------------------------------------------
# render_units — write both service unit FILES for the host init system.
# Does NOT start, stop, or reload any live services. Call load_units after
# render_units when a live reload is desired (fresh install / --force).
# ---------------------------------------------------------------------------
render_units() {
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
        echo "service unit: $_core_plist"

        # Updater unit.
        _upd_plist="$_la_dir/com.burrowee.gateway.updater.plist"
        cat > "$_upd_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.burrowee.gateway.updater</string>
  <key>ProgramArguments</key><array><string>$BIN_DIR/burrowee-gateway-updater</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$GW_HOME/logs/updater.log</string>
  <key>StandardErrorPath</key><string>$GW_HOME/logs/updater.err.log</string>
</dict></plist>
EOF
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
        echo "service unit: $_core_svc"

        # Updater unit.
        _upd_svc="$_sd_dir/burrowee-gateway-updater.service"
        cat > "$_upd_svc" <<EOF
[Unit]
Description=burrowee-gateway updater
After=network-online.target

[Service]
ExecStart=$BIN_DIR/burrowee-gateway-updater run
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF
        echo "service unit: $_upd_svc"
        ;;

    *)
        echo "warning: unsupported OS — skipping service unit installation" >&2
        ;;
    esac
}

# ---------------------------------------------------------------------------
# load_units — (re)load the rendered service units. Separated from render_units
# so update mode can refresh the unit FILES without restarting services (the
# updater restarts the kernel out-of-band; restarting the updater here would
# bootout the very process running this script — see the design doc).
# ---------------------------------------------------------------------------
load_units() {
    case "$(uname -s)" in
    Darwin)
        launchctl bootout   "gui/$(id -u)/com.burrowee.gateway"          2>/dev/null || true
        launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.burrowee.gateway.plist"         2>/dev/null || true
        launchctl bootout   "gui/$(id -u)/com.burrowee.gateway.updater"  2>/dev/null || true
        launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.burrowee.gateway.updater.plist" 2>/dev/null || true
        ;;
    Linux)
        systemctl --user daemon-reload 2>/dev/null || true
        systemctl --user enable --now burrowee-gateway.service         2>/dev/null || true
        systemctl --user enable --now burrowee-gateway-updater.service 2>/dev/null || true
        ;;
    esac
}

# ---------------------------------------------------------------------------
# sha256_of — portable sha256 digest of a file (shasum on darwin, sha256sum on linux).
# ---------------------------------------------------------------------------
sha256_of() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else echo "sha256_of: no shasum or sha256sum found" >&2; exit 1; fi
}

# ---------------------------------------------------------------------------
# Mode dispatch.
# ---------------------------------------------------------------------------

if [ -n "${BURROWEE_UNITS_ONLY:-}" ]; then
    render_units
    load_units
    exit 0
fi

if [ -n "${BURROWEE_UPDATE:-}" ]; then
    # ------------------------------------------------------------------
    # Update mode: per-binary sha256 change detection, transactional swap.
    # ------------------------------------------------------------------

    # Parse --version <ver> if present (does NOT gate the swap; sha256 does).
    _install_version=""
    while [ $# -gt 0 ]; do
        case "$1" in
        --version)
            shift
            if [ $# -gt 0 ]; then
                _install_version="$1"
                shift
            fi
            ;;
        *) shift ;;
        esac
    done

    mkdir -p "$BIN_DIR"

    # Phase 1: detect which binaries changed.
    CHANGED=""
    for b in $BINS; do
        { [ "$b" = "burrowee-gateway-cli" ] || [ "$b" = "burrowee-gateway-updater" ]; } && continue   # updater binaries: updated separately, never during a gateway update
        _staged="./$b"
        [ -f "$_staged" ] || { echo "missing $b in bundle" >&2; exit 1; }
        _staged_sum="$(sha256_of "$_staged")"
        _cur_sum=""
        if [ -f "$BIN_DIR/$b" ]; then
            _cur_sum="$(sha256_of "$BIN_DIR/$b")"
        fi
        if [ "$_staged_sum" != "$_cur_sum" ]; then
            CHANGED="${CHANGED:+$CHANGED }$b"
        fi
    done

    # Phase 2: transactional backup of all to-be-replaced binaries.
    _backed_up=""
    for b in $CHANGED; do
        if [ -f "$BIN_DIR/$b" ]; then
            cp "$BIN_DIR/$b" "$BIN_DIR/$b.bak-$$"
            _backed_up="${_backed_up:+$_backed_up }$b"
        fi
    done

    # Phase 3: place changed binaries; rollback on any failure.
    _placed=""
    for b in $CHANGED; do
        if install -m 0755 "./$b" "$BIN_DIR/$b"; then
            if [ "$(uname -s)" = "Darwin" ]; then
                xattr -d com.apple.quarantine "$BIN_DIR/$b" 2>/dev/null || true
            fi
            _placed="${_placed:+$_placed }$b"
        else
            # Restore all backups and abort.
            for _rb in $_backed_up; do
                if [ -f "$BIN_DIR/$_rb.bak-$$" ]; then
                    cp "$BIN_DIR/$_rb.bak-$$" "$BIN_DIR/$_rb" 2>/dev/null || true
                    rm -f "$BIN_DIR/$_rb.bak-$$"
                fi
            done
            echo "update: failed to install $b — rolled back" >&2
            exit 1
        fi
    done

    # Phase 4: remove backups on success.
    for b in $_backed_up; do
        rm -f "$BIN_DIR/$b.bak-$$"
    done

    # Record installed version if provided.
    if [ -n "$_install_version" ]; then
        mkdir -p "$GW_HOME"
        printf '%s\n' "$_install_version" > "$GW_HOME/.installed-version"
    fi

    # Render unit files only — do NOT load them (the updater restarts the kernel
    # out-of-band; loading here would bootout the very process running this script).
    render_units
    mkdir -p "$GW_HOME"
    cp "$0" "$GW_HOME/install.sh" 2>/dev/null || true

    # Final change-set line (MUST be the last stdout line).
    printf 'BURROWEE_CHANGED=%s\n' "$CHANGED"
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
render_units
load_units

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

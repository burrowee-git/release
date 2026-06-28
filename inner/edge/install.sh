#!/bin/sh
# Burrowee inner installer — edge (POSIX sh, macOS + Linux).
#
# Ships at the ROOT of the verified release zip as `install.sh`. The outer
# bootstrap verifies the zip (minisign + sha256) and ONLY THEN execs this with
# cwd = the unzipped dir, so the binaries sit alongside this script.
#
# ROOT-AWARE: when run as root (`curl ... | sudo sh`, the console-minted system
# install), it installs the binaries to /usr/local/bin and sets up a MANAGED
# ROOT SERVICE — a systemd system unit on Linux, a launchd LaunchDaemon on macOS
# — running `burrowee-edge run`, then enables + (re)starts it. The service's
# config home is /root/.burrowee/edge (HOME=/root in the unit). When run
# unprivileged it keeps the historical behavior: a user-path binary drop under
# $HOME/.local/bin with no service, plus a note that a managed system service
# needs sudo.
#
# The system [Service] block mirrors the relay system unit (Restart / RestartSec
# / TimeoutStopSec / HOME); ExecStart is `<bin> run` (the edge daemon verb).
#
# Idempotent: re-running replaces the binaries + unit and restarts the service,
# so the same one-liner serves both fresh installs and in-place updates.
set -eu

BINS="burrowee burrowee-edge burrowee-edge-cli"
COMP=edge

# ── system (root) install paths ──────────────────────────────────────────────
SYS_BIN_DIR="/usr/local/bin"
SYSTEMD_UNIT="/etc/systemd/system/burrowee-edge.service"
LAUNCHD_PLIST="/Library/LaunchDaemons/org.burrowee.edge.plist"
LAUNCHD_LABEL="org.burrowee.edge"

is_root() { [ "$(id -u)" = 0 ]; }

# ── install target depends on privilege ──────────────────────────────────────
# Root → /usr/local/bin + the root service's config home (/root/.burrowee/edge).
# Non-root → $HOME/.local/bin + the invoking user's ~/.burrowee/edge (unchanged).
if is_root; then
    BIN_DIR="$SYS_BIN_DIR"
    COMP_HOME="/root/.burrowee/$COMP"
else
    BIN_DIR="${PREFIX:-$HOME/.local}/bin"
    COMP_HOME="$HOME/.burrowee/$COMP"
fi
VERSION_MARKER="$COMP_HOME/installed-version"

# ver_lt A B — true (exit 0) when version A < B, comparing the vMAJOR.MINOR.PATCH
# prefix numerically (any .date.sha suffix is ignored). Empty A sorts as 0.0.0.
ver_lt() {
    _a="${1#v}"; _b="${2#v}"
    _a1=$(printf '%s' "$_a" | cut -d. -f1); _a1=$(printf '%s' "${_a1:-0}" | tr -cd 0-9); _a1=${_a1:-0}
    _a2=$(printf '%s' "$_a" | cut -d. -f2); _a2=$(printf '%s' "${_a2:-0}" | tr -cd 0-9); _a2=${_a2:-0}
    _a3=$(printf '%s' "$_a" | cut -d. -f3); _a3=$(printf '%s' "${_a3:-0}" | tr -cd 0-9); _a3=${_a3:-0}
    _b1=$(printf '%s' "$_b" | cut -d. -f1); _b1=$(printf '%s' "${_b1:-0}" | tr -cd 0-9); _b1=${_b1:-0}
    _b2=$(printf '%s' "$_b" | cut -d. -f2); _b2=$(printf '%s' "${_b2:-0}" | tr -cd 0-9); _b2=${_b2:-0}
    _b3=$(printf '%s' "$_b" | cut -d. -f3); _b3=$(printf '%s' "${_b3:-0}" | tr -cd 0-9); _b3=${_b3:-0}
    [ "$_a1" -lt "$_b1" ] && return 0; [ "$_a1" -gt "$_b1" ] && return 1
    [ "$_a2" -lt "$_b2" ] && return 0; [ "$_a2" -gt "$_b2" ] && return 1
    [ "$_a3" -lt "$_b3" ] && return 0
    return 1
}

# seed_if_absent KEY VAL — set the config key only when unset (never clobber an
# operator value). burrowee-edge-cli `config get` exits non-zero when absent.
seed_if_absent() {
    if "$BIN_DIR/burrowee-edge-cli" config get "$1" >/dev/null 2>&1; then
        return 0
    fi
    "$BIN_DIR/burrowee-edge-cli" config set "$1" "$2" >/dev/null 2>&1 \
        || echo "warning: could not seed default $1=$2" >&2
}

# migrate_config OLD — apply version-gated default seeds. Each block runs
# only when crossing into the version that introduced its default.
migrate_config() {
    _old="$1"
    # introduced v0.1.32 — high-throughput smux buffers (the buffer-profile feature):
    if ver_lt "$_old" "v0.1.32"; then
        seed_if_absent buffer_stream  32m
        seed_if_absent buffer_session 256m
    fi
}

# Test seam: when sourced with this var set, stop here so a test harness can call
# the functions above without any install side-effect (tools/test-config-migrate.sh).
# shellcheck disable=SC2317  # the `|| exit 0` IS reached when this script is run (not sourced)
if [ -n "${BURROWEE_INSTALLER_SOURCE_ONLY:-}" ]; then return 0 2>/dev/null || exit 0; fi

if [ -n "${BURROWEE_UNINSTALL:-}" ]; then
    if is_root; then
        if [ "$(uname -s)" = "Darwin" ]; then
            launchctl bootout "system/$LAUNCHD_LABEL" 2>/dev/null || true
            rm -f "$LAUNCHD_PLIST"
        else
            systemctl disable --now burrowee-edge 2>/dev/null || true
            rm -f "$SYSTEMD_UNIT"
            systemctl daemon-reload 2>/dev/null || true
        fi
    fi
    for b in $BINS; do rm -f "$BIN_DIR/$b"; done
    echo "removed from $BIN_DIR: $BINS"
    exit 0
fi

mkdir -p "$BIN_DIR"
for b in $BINS; do
    [ -f "./$b" ] || { echo "missing $b in archive" >&2; exit 1; }
    install -m 0755 "./$b" "$BIN_DIR/$b"
    if [ "$(uname -s)" = "Darwin" ]; then
        xattr -d com.apple.quarantine "$BIN_DIR/$b" 2>/dev/null || true
    fi
done
echo "installed to $BIN_DIR: $BINS"

# ---- cover assets (decoy pages for handleCover file mode) -------------------
# Lay admin.html + default.html into the component covers dir, non-clobbering
# (operator-customized covers survive). Force with BURROWEE_FORCE_COVER=1.
if [ -d "./covers" ]; then
    mkdir -p "$COMP_HOME/covers"
    for cf in admin.html default.html; do
        [ -f "./covers/$cf" ] || continue
        if [ -f "$COMP_HOME/covers/$cf" ] && [ -z "${BURROWEE_FORCE_COVER:-}" ]; then
            continue
        fi
        install -m 0644 "./covers/$cf" "$COMP_HOME/covers/$cf" 2>/dev/null \
            || cp "./covers/$cf" "$COMP_HOME/covers/$cf" 2>/dev/null \
            || echo "warning: could not install cover $cf" >&2
    done
fi

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "note: $BIN_DIR is not on PATH — add: export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

"$BIN_DIR/burrowee" --version 2>/dev/null || true

# ---- version-gated config migration ---------------------------------------
# Roll new default config onto existing installs (seed-if-absent), gated by the
# prior installed version. Best-effort; never aborts the install/update.
if [ -n "${BURROWEE_VERSION:-}" ]; then
    OLD_VER=""
    [ -f "$VERSION_MARKER" ] && OLD_VER="$(cat "$VERSION_MARKER" 2>/dev/null || true)"
    migrate_config "$OLD_VER" || echo "warning: config migration step failed; continuing" >&2
    mkdir -p "$COMP_HOME" 2>/dev/null || true
    if printf '%s\n' "$BURROWEE_VERSION" > "$VERSION_MARKER.tmp" 2>/dev/null; then
        mv -f "$VERSION_MARKER.tmp" "$VERSION_MARKER" 2>/dev/null || echo "warning: could not record installed version" >&2
    else
        echo "warning: could not write version marker" >&2
    fi
fi

# ---- ROOT: managed system service ------------------------------------------
# A root install sets up a managed root service running `burrowee-edge run` and
# (re)starts it, so the same one-liner is a fresh install AND an in-place update.
# Non-root installs skip this and fall through to the user-path note + first-run
# bootstrap below.
if is_root; then
    if [ "$(uname -s)" = "Darwin" ]; then
        # ── macOS: root LaunchDaemon ──────────────────────────────────────────
        cat > "$LAUNCHD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LAUNCHD_LABEL</string>
  <key>ProgramArguments</key><array><string>$SYS_BIN_DIR/burrowee-edge</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>2</integer>
</dict></plist>
EOF
        chmod 0644 "$LAUNCHD_PLIST"
        echo "wrote LaunchDaemon → $LAUNCHD_PLIST"
        launchctl bootout "system/$LAUNCHD_LABEL" 2>/dev/null || true
        launchctl bootstrap system "$LAUNCHD_PLIST"
        launchctl enable "system/$LAUNCHD_LABEL"
        launchctl kickstart -k "system/$LAUNCHD_LABEL" 2>/dev/null || true
        echo "launchd service $LAUNCHD_LABEL enabled + started"
    else
        # ── Linux: systemd system unit ([Service] mirrors the relay unit) ─────
        # HOME=/root so the daemon's os.UserHomeDir() resolves /root/.burrowee/edge
        # (a root system service has no HOME otherwise).
        mkdir -p "$(dirname "$SYSTEMD_UNIT")"
        cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=burrowee edge (self-hosted relay-edge)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=/root
ExecStart=$SYS_BIN_DIR/burrowee-edge run
Restart=on-failure
RestartSec=2
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
        chmod 0644 "$SYSTEMD_UNIT"
        echo "wrote systemd unit → $SYSTEMD_UNIT"
        systemctl daemon-reload
        systemctl enable --now burrowee-edge
        systemctl restart burrowee-edge
        echo "systemd service burrowee-edge enabled + (re)started"
    fi
    "$SYS_BIN_DIR/burrowee-edge" version 2>/dev/null || true
    echo "edge system install complete."
    # The managed service runs the daemon; pairing is a separate operator step:
    #   burrowee edge cli bootstrap <blob> <pin>   (or via the console)
    if [ ! -d "$COMP_HOME/identity" ] && [ ! -f "$COMP_HOME/console.json" ]; then
        echo "next: pair this edge — burrowee edge cli bootstrap <blob> <pin>"
    fi
    exit 0
fi

# ---- NON-ROOT: user-path note ----------------------------------------------
echo "note: installed to $BIN_DIR (user path, no managed service);"
echo "      for a managed system service re-run with sudo."

# ---- first-run bootstrap (interactive only, fresh installs) -------------------
# Re-install short-circuit: if this component already has persisted state under
# ~/.burrowee/<comp> (the gateway db/keys, cli/edge identity, …) it is already
# set up — never re-prompt for a setup blob. Otherwise read blob+PIN from the
# controlling terminal (stdin is the curl pipe, not a tty): prompt only if
# /dev/tty is genuinely usable (fd 3); if not (CI / detached) just print the
# next step. All tty I/O is fault-tolerant so it can never abort the install.
# An ENROLLED install has an identity (and usually console.json). Test that
# artifact specifically — NOT a non-empty COMP_HOME, which now also holds the
# config + installed-version marker written by the migration step above.
if [ -d "$COMP_HOME/identity" ] || [ -f "$COMP_HOME/console.json" ]; then
    echo "$COMP already set up ($COMP_HOME) — skipping setup."
elif { exec 3<>/dev/tty; } 2>/dev/null; then
    printf '\nSet up now? Paste the setup blob + PIN from the console (Enter to skip).\n' >&3 2>/dev/null || true
    printf 'blob> ' >&3 2>/dev/null || true
    blob=''; IFS= read -r blob <&3 2>/dev/null || blob=''
    if [ -n "$blob" ]; then
        printf 'pin>  ' >&3 2>/dev/null || true
        pin=''; IFS= read -r pin <&3 2>/dev/null || pin=''
        if [ -n "$pin" ]; then
            "$BIN_DIR/burrowee" "$COMP" cli bootstrap "$blob" "$pin" <&3 || true
        else
            printf 'No PIN — skipped. Run later: burrowee %s cli bootstrap <blob> <pin>\n' "$COMP" >&3 2>/dev/null || true
        fi
    else
        printf 'Skipped. Run later: burrowee %s cli bootstrap <blob> <pin>\n' "$COMP" >&3 2>/dev/null || true
    fi
    exec 3>&- 2>/dev/null || true
else
    echo "next: burrowee $COMP cli bootstrap <blob> <pin>"
fi

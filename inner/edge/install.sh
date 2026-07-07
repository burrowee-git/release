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
# config home is root's home + /.burrowee/edge — /root on Linux, /var/root on
# macOS (NOT /root, which sits on the sealed system volume) — and HOME is set
# to it in the unit/plist so the daemon resolves the same dir. When run
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

BINS="burrowee burrowee-edge burrowee-edge-cli burrowee-edge-updater"
COMP=edge

# ── system (root) install paths ──────────────────────────────────────────────
# SYS_BIN_DIR + SYSTEMD_UNIT_DIR + LAUNCHD_PLIST_DIR default to the real system
# locations; they are overridable only so the Go install-test harness can
# exercise the root branch in a sandbox without actually being root.
SYS_BIN_DIR="${SYS_BIN_DIR:-/usr/local/bin}"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
SYSTEMD_UNIT="$SYSTEMD_UNIT_DIR/burrowee-edge.service"
SYSTEMD_UPDATER_UNIT="$SYSTEMD_UNIT_DIR/burrowee-edge-updater.service"
LAUNCHD_PLIST_DIR="${LAUNCHD_PLIST_DIR:-/Library/LaunchDaemons}"
LAUNCHD_PLIST="$LAUNCHD_PLIST_DIR/org.burrowee.edge.plist"
LAUNCHD_LABEL="org.burrowee.edge"
LAUNCHD_UPDATER_PLIST="$LAUNCHD_PLIST_DIR/org.burrowee.edge.updater.plist"
LAUNCHD_UPDATER_LABEL="org.burrowee.edge.updater"

is_root() { [ "$(id -u)" = 0 ]; }

# ── install target depends on privilege ──────────────────────────────────────
# Root → /usr/local/bin + the root service's config home (root's home +
# /.burrowee/edge). Root's home is /root on Linux but /var/root on macOS — /root
# sits on the sealed read-only system volume there, so any mkdir under it fails.
# Resolve it robustly (tilde expansion), falling back to the well-known
# /var/root; ROOT_HOME is overridable only for the Go install-test harness
# (like SYS_BIN_DIR).
# Non-root → $HOME/.local/bin + the invoking user's ~/.burrowee/edge (unchanged).
if is_root; then
    BIN_DIR="$SYS_BIN_DIR"
    if [ "$(uname -s)" = "Darwin" ]; then
        ROOT_HOME="${ROOT_HOME:-$(eval echo ~root)}"
        case "$ROOT_HOME" in /*) ;; *) ROOT_HOME=/var/root ;; esac
    else
        ROOT_HOME="${ROOT_HOME:-/root}"
    fi
    COMP_HOME="$ROOT_HOME/.burrowee/$COMP"
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
            launchctl bootout "system/$LAUNCHD_UPDATER_LABEL" 2>/dev/null || true
            rm -f "$LAUNCHD_PLIST" "$LAUNCHD_UPDATER_PLIST"
        else
            systemctl disable --now burrowee-edge 2>/dev/null || true
            systemctl disable --now burrowee-edge-updater 2>/dev/null || true
            rm -f "$SYSTEMD_UNIT" "$SYSTEMD_UPDATER_UNIT"
            systemctl daemon-reload 2>/dev/null || true
        fi
    fi
    removed=""
    for b in $BINS; do
        case "$b" in burrowee) continue ;; esac
        rm -f "$BIN_DIR/$b"
        removed="$removed $b"
    done
    # The bare `burrowee` dispatcher is SHARED across co-installed components
    # (e.g. a relay on the same host) — remove it only when no other
    # burrowee-* binary remains in $BIN_DIR.
    if ls "$BIN_DIR"/burrowee-* >/dev/null 2>&1; then
        echo "kept $BIN_DIR/burrowee (dispatcher) — other burrowee components remain installed"
    else
        rm -f "$BIN_DIR/burrowee"
        removed="$removed burrowee"
    fi
    echo "removed from $BIN_DIR:$removed"
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
# Always refresh the two SHIPPED defaults (admin.html + default.html) on every
# install/update: a stale hardcoded footer blows the decoy, so the shipped covers
# must track the release. Operator-added per-host <host>.html covers are not
# enumerated here, so they survive untouched (and still win in selectCover).
if [ -d "./covers" ]; then
    mkdir -p "$COMP_HOME/covers"
    for cf in admin.html default.html; do
        [ -f "./covers/$cf" ] || continue
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
        # HOME=$ROOT_HOME (/var/root) so the daemon's os.UserHomeDir() resolves
        # $ROOT_HOME/.burrowee/edge — launchd daemons get no HOME by default
        # (mirrors the systemd unit's Environment=HOME=/root).
        cat > "$LAUNCHD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LAUNCHD_LABEL</string>
  <key>ProgramArguments</key><array><string>$SYS_BIN_DIR/burrowee-edge</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>2</integer>
  <key>EnvironmentVariables</key><dict><key>HOME</key><string>$ROOT_HOME</string></dict>
</dict></plist>
EOF
        chmod 0644 "$LAUNCHD_PLIST"
        echo "wrote LaunchDaemon → $LAUNCHD_PLIST"

        # Updater LaunchDaemon (mirrors the disabled systemd updater unit; HOME
        # so its console.json + identity resolve under $ROOT_HOME/.burrowee/edge).
        # Rendered but NOT bootstrapped — the auto-updater is owner opt-in.
        cat > "$LAUNCHD_UPDATER_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LAUNCHD_UPDATER_LABEL</string>
  <key>ProgramArguments</key><array><string>$SYS_BIN_DIR/burrowee-edge-updater</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>2</integer>
  <key>EnvironmentVariables</key><dict><key>HOME</key><string>$ROOT_HOME</string></dict>
</dict></plist>
EOF
        chmod 0644 "$LAUNCHD_UPDATER_PLIST"
        echo "wrote LaunchDaemon → $LAUNCHD_UPDATER_PLIST (not bootstrapped — enable with: launchctl bootstrap system $LAUNCHD_UPDATER_PLIST)"

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

        # Updater system unit ([Service] mirrors the serve unit; HOME=/root so its
        # console.json + identity resolve to /root/.burrowee/edge). Rendered but
        # left DISABLED — the auto-updater is owner opt-in (enable + start it with
        # `systemctl enable --now burrowee-edge-updater`).
        cat > "$SYSTEMD_UPDATER_UNIT" <<EOF
[Unit]
Description=burrowee edge updater
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=/root
ExecStart=$SYS_BIN_DIR/burrowee-edge-updater run
Restart=on-failure
RestartSec=2
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
        chmod 0644 "$SYSTEMD_UPDATER_UNIT"
        echo "wrote systemd unit → $SYSTEMD_UPDATER_UNIT (disabled — enable with: systemctl enable --now burrowee-edge-updater)"

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

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
# needs sudo. A ROOT install additionally sweeps the copies an earlier
# unprivileged install left in that per-user directory, which would otherwise
# shadow /usr/local/bin on PATH — remove_stale_user_bins.
#
# The system [Service] block mirrors the relay system unit (Restart / RestartSec
# / TimeoutStopSec / HOME); ExecStart is `<bin> run` (the edge daemon verb).
#
# Idempotent: re-running replaces the binaries + unit and restarts the service,
# so the same one-liner serves both fresh installs and in-place updates.
#
# Set BURROWEE_UNITS_ONLY=1 to re-render + reload the managed service units
# without touching binaries or the network — the offline reinstall entrypoint
# run by the component's LocalReinstall.
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
LAUNCHD_PLIST="$LAUNCHD_PLIST_DIR/com.burrowee.edge.plist"
LAUNCHD_LABEL="com.burrowee.edge"
LAUNCHD_UPDATER_PLIST="$LAUNCHD_PLIST_DIR/com.burrowee.edge.updater.plist"
LAUNCHD_UPDATER_LABEL="com.burrowee.edge.updater"
# Legacy pre-rename system labels/plists earlier installers wrote — migrated
# away on install, removed on uninstall.
LEGACY_LAUNCHD_LABEL="org.burrowee.edge"
LEGACY_LAUNCHD_UPDATER_LABEL="org.burrowee.edge.updater"

# remove_legacy_launchd_units — boot out + delete the org.burrowee.* system
# LaunchDaemons a pre-rename root install wrote. Best-effort; root-only caller.
remove_legacy_launchd_units() {
    launchctl bootout "system/$LEGACY_LAUNCHD_LABEL" 2>/dev/null || true
    launchctl bootout "system/$LEGACY_LAUNCHD_UPDATER_LABEL" 2>/dev/null || true
    rm -f "$LAUNCHD_PLIST_DIR/$LEGACY_LAUNCHD_LABEL.plist" \
          "$LAUNCHD_PLIST_DIR/$LEGACY_LAUNCHD_UPDATER_LABEL.plist"
}

is_root() { [ "$(id -u)" = 0 ]; }

# ---------------------------------------------------------------------------
# Stale per-user binaries, left by an UNPRIVILEGED install of this component.
#
# The non-root branch below still drops the binaries in $HOME/.local/bin, and
# before the managed root service existed that was the only shape an edge
# install took. A host that later installs as root gets everything in
# /usr/local/bin and keeps the old copies — and $HOME/.local/bin PRECEDES
# /usr/local/bin on a normal PATH, so every unqualified `burrowee` or
# `burrowee-edge-cli` an operator types resolves to the OLD binary while the
# system unit runs the new one. The gateway's sibling installer carries the
# same sweep, for the same reason, with the same ordering rule.
#
# THE ORDERING IS A SAFETY PROPERTY. A host arriving here may still be running
# a unit whose ExecStart names the per-user path; the macOS LaunchDaemons this
# script writes gate KeepAlive on PathState, so unlinking the binary does not
# stale a future restart — it stops the running daemon. The sweep therefore
# runs only after the new binaries are in $SYS_BIN_DIR and the units naming
# them have been rendered and (re)loaded, and it refuses outright when a unit
# file on this host still names the old directory.
# ---------------------------------------------------------------------------

# LEGACY_HOME_PARENTS — where an account's home may live on a host with neither
# getent nor dscl. Same name and default as the gateway's installer and the
# gateway repo's migrations/run.sh, so one override covers all of them.
LEGACY_HOME_PARENTS="${BURROWEE_LEGACY_HOME_PARENTS:-/Users /home}"

# home_of_user <name> — that account's home directory, or empty + non-zero:
# getent on Linux, dscl on macOS, a parent-directory guess for a slim image.
home_of_user() {
    _hu=""
    if command -v getent >/dev/null 2>&1; then
        _hu="$(getent passwd "$1" 2>/dev/null | cut -d: -f6)"
    fi
    if [ -z "$_hu" ] && command -v dscl >/dev/null 2>&1; then
        _hu="$(dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')"
    fi
    if [ -z "$_hu" ]; then
        for _hu_p in $LEGACY_HOME_PARENTS; do
            if [ -d "$_hu_p/$1" ]; then _hu="$_hu_p/$1"; break; fi
        done
    fi
    [ -n "$_hu" ] || return 1
    echo "$_hu"
}

# operator_home — the home of the account whose per-user tree an earlier
# unprivileged install wrote to, which is NOT $HOME on the path that matters:
# the documented flow is `curl … | sudo sh`, and under sudo $HOME is root's
# (/root, or /var/root on macOS). A sweep aimed at $HOME/.local/bin would look
# in a tree no unprivileged install ever wrote to, find nothing, and report
# success — a check whose scope is narrower than its claim. $SUDO_USER is who
# invoked sudo; it is unset for a genuine root login, where $HOME is already
# the right answer.
operator_home() {
    case "${SUDO_USER:-}" in
    '' | root) ;;
    *)
        if _oh="$(home_of_user "$SUDO_USER")" && [ -n "$_oh" ]; then
            echo "$_oh"
            return 0
        fi
        echo "note: \$SUDO_USER='$SUDO_USER' has no resolvable home — the stale per-user" >&2
        echo "note: binary sweep falls back to \$HOME." >&2
        ;;
    esac
    echo "${HOME:-}"
}

# unit_naming_dir <dir> <operator-home> — the first service unit file on this
# host that still names <dir>, or empty + non-zero when none does. It reads the
# unit FILES rather than asking the supervisor and treats one on disk as
# possibly loaded: the two outcomes are "skip a cleanup" and "stop a running
# daemon", and only one of them is undone by running the installer again.
unit_naming_dir() {
    for _und_d in "$LAUNCHD_PLIST_DIR" "$SYSTEMD_UNIT_DIR" \
        "$2/Library/LaunchAgents" "$2/.config/systemd/user"; do
        [ -d "$_und_d" ] || continue
        for _und_f in "$_und_d"/*; do
            [ -f "$_und_f" ] || continue
            if grep -qF "$1/" "$_und_f" 2>/dev/null; then
                echo "$_und_f"
                return 0
            fi
        done
    done
    return 1
}

# is_burrowee_binary <file> — whether <file> is one of OURS, decided by reading
# it and never by running it.
#
# Every burrowee binary is a Go binary built from a github.com/burrowee-git/*
# module, and the toolchain stamps that module path into the executable's
# build-info blob (the bytes `go version -m` reads back). It survives -trimpath
# and -ldflags "-s -w", so a release build carries it too.
#
# NOT `"$file" --version`. This installer runs as root on the path that
# matters, and the directory being swept is writable by the very user whose
# files are in question — executing one of them to ask what it is would hand
# uid 0 to whoever can drop a file there. Reading a file grants it nothing.
is_burrowee_binary() {
    LC_ALL=C grep -qF 'github.com/burrowee-git/' "$1" 2>/dev/null
}

# stale_dir_has_other_burrowee_bin <dir> — whether any burrowee-* binary of
# OURS remains in <dir> after this component's own names have been swept. The
# glob is a DETECTION over what is left, never a removal target: nothing is ever
# deleted by pattern here, only by exact name out of $BINS. Each candidate is
# put to is_burrowee_binary so an operator's own `burrowee-notes` script cannot
# stand in for an installed component and pin the shadowing dispatcher forever.
stale_dir_has_other_burrowee_bin() {
    for _sdo_f in "$1"/burrowee-*; do
        [ -f "$_sdo_f" ] || continue
        if is_burrowee_binary "$_sdo_f"; then return 0; fi
    done
    return 1
}

# remove_one_stale_bin <path> — remove ONE stale per-user copy, and only when it
# is provably ours. Absent is success, not a warning.
remove_one_stale_bin() {
    _ros_p="$1"
    if [ -h "$_ros_p" ]; then
        echo "note: $_ros_p is a symlink, not a binary this installer placed — left in place." >&2
        return 0
    fi
    [ -e "$_ros_p" ] || return 0
    if [ ! -f "$_ros_p" ]; then
        echo "note: $_ros_p is not a regular file — left in place." >&2
        return 0
    fi
    if ! is_burrowee_binary "$_ros_p"; then
        echo "note: $_ros_p carries no burrowee build stamp — it is not ours, left in place." >&2
        return 0
    fi
    if rm -f "$_ros_p"; then
        echo "removed stale per-user binary: $_ros_p"
    else
        echo "note: could not remove $_ros_p — it shadows $BIN_DIR on PATH; remove it by hand." >&2
    fi
}

# remove_stale_user_bins — sweep the per-user copies of THIS component's
# binaries, by exact name out of $BINS and never by glob. Root-only caller:
# an unprivileged install's $BIN_DIR IS that directory, and the guard below
# refuses that case a second time rather than relying on the call site.
remove_stale_user_bins() {
    _rsb_home="$(operator_home)"
    [ -n "$_rsb_home" ] || return 0
    _rsb_dir="$_rsb_home/.local/bin"
    [ -d "$_rsb_dir" ] || return 0
    if [ "$_rsb_dir" = "$BIN_DIR" ]; then return 0; fi

    _rsb_unit=""
    _rsb_unit="$(unit_naming_dir "$_rsb_dir" "$_rsb_home")" || _rsb_unit=""
    if [ -n "$_rsb_unit" ]; then
        echo "note: $_rsb_unit still names $_rsb_dir, so a supervisor may be running a" >&2
        echo "note: binary from there — the stale per-user copies are left in place." >&2
        echo "hint: remove them by hand once nothing points at that directory." >&2
        return 0
    fi

    for _rsb_b in $BINS; do
        # The bare `burrowee` dispatcher is SHARED across co-installed
        # components (cli still installs per-user by design), so it is handled
        # after this component's own names and only when nothing else remains —
        # the same rule the uninstall path below applies to $BIN_DIR.
        case "$_rsb_b" in burrowee) continue ;; esac
        remove_one_stale_bin "$_rsb_dir/$_rsb_b"
    done
    if stale_dir_has_other_burrowee_bin "$_rsb_dir"; then
        echo "kept $_rsb_dir/burrowee (dispatcher) — another burrowee component is still installed there"
    else
        remove_one_stale_bin "$_rsb_dir/burrowee"
    fi
}

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

# setup_root_service — render BOTH managed SYSTEM service units for the host init
# system and (re)load the serve unit (the updater unit is rendered but left
# opt-in). Root-only caller. Renders unit FILES pointing at $SYS_BIN_DIR; it
# never places binaries, so it is safe to call from the units-only reinstall
# path as well as fresh install / update.
setup_root_service() {
    if [ "$(uname -s)" = "Darwin" ]; then
        # ── macOS: root LaunchDaemon ──────────────────────────────────────────
        # HOME=$ROOT_HOME (/var/root) so the daemon's os.UserHomeDir() resolves
        # $ROOT_HOME/.burrowee/edge — launchd daemons get no HOME by default
        # (mirrors the systemd unit's Environment=HOME=/root).
        # KeepAlive.PathState (matching core/setup's system units, which land on
        # the SAME paths): the update-restart rung SIGTERMs the running daemon
        # and relies on the supervisor respawning it after a CLEAN exit —
        # SuccessfulExit=false would leave a cleanly-exited daemon down.
        cat > "$LAUNCHD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LAUNCHD_LABEL</string>
  <key>ProgramArguments</key><array><string>$SYS_BIN_DIR/burrowee-edge</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>PathState</key><dict><key>$SYS_BIN_DIR/burrowee-edge</key><true/></dict></dict>
  <key>ThrottleInterval</key><integer>10</integer>
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
  <key>KeepAlive</key><dict><key>PathState</key><dict><key>$SYS_BIN_DIR/burrowee-edge-updater</key><true/></dict></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>EnvironmentVariables</key><dict><key>HOME</key><string>$ROOT_HOME</string></dict>
</dict></plist>
EOF
        chmod 0644 "$LAUNCHD_UPDATER_PLIST"
        echo "wrote LaunchDaemon → $LAUNCHD_UPDATER_PLIST (not bootstrapped — enable with: launchctl bootstrap system $LAUNCHD_UPDATER_PLIST)"

        # Migrate away the pre-rename org.burrowee.* units before loading the
        # com.burrowee.* ones — two labels must never run the same daemon.
        remove_legacy_launchd_units

        launchctl bootout "system/$LAUNCHD_LABEL" 2>/dev/null || true
        launchctl bootstrap system "$LAUNCHD_PLIST"
        launchctl enable "system/$LAUNCHD_LABEL"
        launchctl kickstart -k "system/$LAUNCHD_LABEL" 2>/dev/null || true
        echo "launchd service $LAUNCHD_LABEL enabled + started"

        # If the owner opted the auto-updater in (its LaunchDaemon is already
        # loaded), a reinstall must advance THAT daemon too — otherwise a stale
        # updater keeps running old code and future pushes deadlock. Restart it
        # ONLY when already loaded; never bootstrap a not-loaded updater here (it
        # stays owner opt-in). The updater's own push path runs update.sh, not this
        # installer, so this can never self-kill.
        if launchctl print "system/$LAUNCHD_UPDATER_LABEL" >/dev/null 2>&1; then
            launchctl kickstart -k "system/$LAUNCHD_UPDATER_LABEL" 2>/dev/null || true
            echo "restarted $LAUNCHD_UPDATER_LABEL (opted in) to pick up new binary"
        fi
    else
        # ── Linux: systemd system unit ([Service] mirrors the relay unit) ─────
        # HOME=/root so the daemon's os.UserHomeDir() resolves /root/.burrowee/edge
        # (a root system service has no HOME otherwise).
        # Restart=always (matching core/setup's system units, which land on the
        # SAME paths): the update-restart rung SIGTERMs the running daemon and
        # relies on systemd respawning it after a CLEAN exit — on-failure would
        # leave a cleanly-exited daemon down.
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
Restart=always
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
Restart=always
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

        # If the owner opted the auto-updater in, a reinstall must advance THAT
        # daemon too — otherwise a stale updater keeps running old code and future
        # pushes deadlock. Restart it ONLY when already enabled/active; never enable
        # a disabled updater here (it stays owner opt-in). The updater's own push
        # path runs update.sh, not this installer, so this can never self-kill.
        if systemctl is-enabled burrowee-edge-updater >/dev/null 2>&1 \
            || systemctl is-active burrowee-edge-updater >/dev/null 2>&1; then
            systemctl restart burrowee-edge-updater 2>/dev/null || true
            echo "restarted burrowee-edge-updater (opted in) to pick up new binary"
        fi
    fi
}

# Test seam: when sourced with this var set, stop here so a test harness can call
# the functions above without any install side-effect (tools/test-config-migrate.sh).
# shellcheck disable=SC2317  # the `|| exit 0` IS reached when this script is run (not sourced)
if [ -n "${BURROWEE_INSTALLER_SOURCE_ONLY:-}" ]; then return 0 2>/dev/null || exit 0; fi

# ---------------------------------------------------------------------------
# Units-only mode (BURROWEE_UNITS_ONLY=1): the offline reinstall entrypoint run
# by edge's LocalReinstall. Re-render + reload the managed service units WITHOUT
# placing binaries or touching the network. A root install has a managed system
# service, so re-render it; an unprivileged install has no service, so this is a
# successful no-op (mirrors cli).
# ---------------------------------------------------------------------------
if [ -n "${BURROWEE_UNITS_ONLY:-}" ]; then
    if is_root; then
        setup_root_service
        echo "edge units-only reinstall: service units re-rendered + reloaded."
    else
        echo "edge units-only reinstall: no user-level service (edge service is root-managed) — nothing to do."
    fi
    exit 0
fi

if [ -n "${BURROWEE_UNINSTALL:-}" ]; then
    if is_root; then
        if [ "$(uname -s)" = "Darwin" ]; then
            launchctl bootout "system/$LAUNCHD_LABEL" 2>/dev/null || true
            launchctl bootout "system/$LAUNCHD_UPDATER_LABEL" 2>/dev/null || true
            rm -f "$LAUNCHD_PLIST" "$LAUNCHD_UPDATER_PLIST"
            remove_legacy_launchd_units
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

# Self-copy: keep a copy of this installer at $COMP_HOME/install.sh so an offline
# units-only reinstall (BURROWEE_UNITS_ONLY=1, run by edge's LocalReinstall) can
# re-render + reload the service units without a fresh download.
mkdir -p "$COMP_HOME" 2>/dev/null || true
cp "$0" "$COMP_HOME/install.sh" 2>/dev/null || true

# ---- ROOT: managed system service ------------------------------------------
# A root install sets up a managed root service running `burrowee-edge run` and
# (re)starts it, so the same one-liner is a fresh install AND an in-place update.
# Non-root installs skip this and fall through to the user-path note + first-run
# bootstrap below.
if is_root; then
    setup_root_service
    # Only now: the binaries are in $SYS_BIN_DIR and the units naming them are
    # not merely written but loaded. Deliberately NOT in BURROWEE_UNITS_ONLY
    # mode above — that path places no binaries at all, so the precondition
    # this sweep's safety rests on ("the new copies are already in place") is
    # not something that mode establishes.
    remove_stale_user_bins
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

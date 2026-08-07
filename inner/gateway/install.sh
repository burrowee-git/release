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
# and a final BURROWEE_CHANGED=<names> line. In update mode, BURROWEE_FORCE=1
# bypasses the sha256 check and re-places every serve binary (the `--force`
# full-reinstall path — the diff would otherwise skip an identical version).
#
# Service model: the service units are SYSTEM-level and the daemon they start
# runs as ROOT, so the gateway starts at boot without a GUI login:
# /Library/LaunchDaemons on macOS, /etc/systemd/system on Linux. Its config and
# data live under the SYSTEM roots ($SYS_CONFIG_DIR / $SYS_DATA_DIR), named
# explicitly in the unit rather than left to resolve from whoever's environment
# the daemon happens to inherit. System steps run via sudo (prompting on the
# controlling tty; with no tty and no cached credentials the unit step aborts
# with guidance).
#
# TWO BINARY LOCATIONS, AND THE DIFFERENCE IS THE WHOLE POINT.
#
#   $BIN_DIR      per-user, on PATH ($PREFIX/bin, default ~/.local/bin). Every
#                 binary, exactly as before. This is what the operator types and
#                 what an unprivileged install has.
#   $LIBEXEC_DIR  root-owned, not on PATH. The subset that something running AS
#                 ROOT execs with nobody watching: the daemon, the console child
#                 it spawns, the updater agent, the cli the migration shells to —
#                 plus this script and its migrations/.
#
# The units name $LIBEXEC_DIR, never $BIN_DIR. A root unit naming a per-user path
# is a permanent uid-0 grant to that user: they overwrite the file after the one
# install-time sudo and wait for a reboot, a KeepAlive cycle, or a pushed update.
# That also made every permission inside $SYS_CONFIG_DIR decorative, because
# whoever can rewrite the binary already owns identity/ and console.token.
#
# Nothing about the unprivileged flow changes: $BIN_DIR is still populated first
# and in full, so a host that cannot reach root still gets working binaries — it
# just gets no units, which was already true.
#
# Because a root-scheme unit runs as nobody in particular, it records no owner
# and the single system slot is free for any installer to replace. Only a
# LEGACY per-user unit (one that still carries UserName / User=) is owned, and
# replacing another user's needs consent — a /dev/tty prompt, or
# BURROWEE_FORCE_SERVICE_OVERRIDE=1 when non-interactive.
#
# The unit body must stay byte-identical to what the gateway's own renderer
# emits (internal/gateway/service_install.go: LaunchdPlist / SystemdUnit and
# their updater twins). Both writers rewrite whenever content differs and then
# reload, so any divergence here does not merely disagree — it makes the two
# writers fight, booting the daemon out on every refresh.
set -eu

BIN_DIR="${PREFIX:-$HOME/.local}/bin"
BINS="burrowee burrowee-gateway burrowee-gateway-cli burrowee-gateway-console burrowee-register burrowee-gateway-updater"
COMP=gateway
GW_HOME="$HOME/.burrowee/gateway"
# The per-user component tree. Identical to $GW_HOME for this component, spelled
# separately because the first-run bootstrap probe at the bottom is written in
# terms of "this component's home" and reads better that way.
COMP_HOME="$HOME/.burrowee/$COMP"
# The invoking user. No longer rendered into any unit (the daemon runs as root)
# — it is only compared against the owner a LEGACY per-user unit still records,
# to decide whether taking over the slot needs consent.
SERVICE_USER="$(id -un)"
# System unit locations. The BURROWEE_*_DIR overrides are test seams for the
# sandboxed installer harness — never set them in production.
LAUNCHD_DIR="${BURROWEE_LAUNCHD_DIR:-/Library/LaunchDaemons}"
SYSTEMD_DIR="${BURROWEE_SYSTEMD_DIR:-/etc/systemd/system}"
# The root daemon's config and data roots — the same two constants the Go side
# holds as systemConfigDir/systemDataDir (internal/gateway/home.go). They are
# written into the units, so they must not drift from that pair. Same test-seam
# caveat as above.
SYS_CONFIG_DIR="${BURROWEE_SYSTEM_CONFIG_DIR:-/usr/local/etc/burrowee/gateway}"
SYS_DATA_DIR="${BURROWEE_SYSTEM_DATA_DIR:-/usr/local/var/burrowee/gateway}"
SYS_LOG_DIR="$SYS_DATA_DIR/logs"
# The PRIVILEGED EXECUTION SURFACE — the root-owned tree the system units and the
# root updater run out of. Sibling of the system config/data roots so the whole
# root-scheme install is one tree, and libexec because that is the conventional
# home for programs invoked by other programs rather than typed, which is exactly
# what an ExecStart is. Same test-seam caveat as the roots above; the Go side
# holds the same constant as internal/gateway/root_exec.go's libexecDir.
LIBEXEC_DIR="${BURROWEE_LIBEXEC_DIR:-/usr/local/libexec/burrowee/gateway}"
# The binaries a ROOT process execs unattended, and therefore the ones that must
# come from a tree no unprivileged user can rewrite:
#   burrowee-gateway          the daemon named in the core unit
#   burrowee-gateway-console  spawned + supervised by that daemon, from its own dir
#   burrowee-gateway-updater  the daemon named in the updater unit
#   burrowee-gateway-cli      execed as root by migrations/v1_to_v2.sh, which the
#                             console-push path runs with no operator present
# burrowee and burrowee-register are NOT here: nothing running as root execs
# them, and keeping them out of the privileged tree keeps that tree honest about
# what it is for.
ROOT_BINS="burrowee-gateway burrowee-gateway-console burrowee-gateway-updater burrowee-gateway-cli"

# ---------------------------------------------------------------------------
# has_tty — whether a controlling terminal is available for prompts (stdin is
# usually the curl pipe, so probe /dev/tty as well).
# ---------------------------------------------------------------------------
has_tty() {
    [ -t 0 ] && return 0
    ( exec </dev/tty ) 2>/dev/null
}

# ---------------------------------------------------------------------------
# run_root — run a system-mutation command as root: directly when already
# root, via sudo (which prompts on the controlling tty) when interactive, via
# `sudo -n` otherwise. Returns non-zero with guidance when root cannot be
# obtained; under `set -e` that aborts unless the caller opts out with `|| …`.
# ---------------------------------------------------------------------------
run_root() {
    if [ "$(id -u)" = 0 ]; then "$@"; return; fi
    if has_tty; then sudo "$@"; return; fi
    if sudo -n "$@" 2>/dev/null; then return 0; fi
    echo "error: 'sudo $*' failed — no tty for a password prompt and no cached sudo credentials." >&2
    echo "hint: re-run from an interactive terminal, or pre-authorize with 'sudo -v', then retry ('burrowee gateway service install')." >&2
    return 1
}

# ---------------------------------------------------------------------------
# The privileged execution surface.
#
# have_real_root — whether elevation on this host actually yields uid 0.
#
# Everything below asserts OWNERSHIP, and ownership can only be asserted where
# root was genuinely obtained. The sandboxed installer harness supplies a
# pass-through `sudo` stub, so every file it "installs as root" is owned by the
# test user: asserting uid 0 there would refuse every test run for a reason that
# says nothing about a real host. Asking the elevation path who it is answers the
# question directly, and keeps the production assertion strict without a second
# env seam that nobody reading the code can see.
#
# Cached, because it costs a sudo round trip.
# ---------------------------------------------------------------------------
HAVE_REAL_ROOT=""
have_real_root() {
    if [ -z "$HAVE_REAL_ROOT" ]; then
        if [ "$(run_root id -u 2>/dev/null || echo -)" = 0 ]; then
            HAVE_REAL_ROOT=yes
        else
            HAVE_REAL_ROOT=no
        fi
    fi
    [ "$HAVE_REAL_ROOT" = yes ]
}

# stat_uid / stat_mode <path> — owner uid and octal permission bits, on both
# stat dialects (BSD/macOS `-f`, GNU `-c`). Empty output on failure.
stat_uid() {
    stat -f '%u' "$1" 2>/dev/null || stat -c '%u' "$1" 2>/dev/null
}
stat_mode() {
    stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

# mode_allows_nonroot_write <octal> — true when the group or other digit carries
# the write bit. The last two characters are those two digits for every width
# stat emits ("755", "1777"), so no zero-padding assumption is needed.
mode_allows_nonroot_write() {
    _mm="$1"
    [ "${#_mm}" -ge 2 ] || return 0    # unreadable mode: assume the worst
    _mg=$(printf '%s' "$_mm" | cut -c "$((${#_mm} - 1))")
    _mo=$(printf '%s' "$_mm" | cut -c "${#_mm}")
    case "$_mg" in 2 | 3 | 6 | 7) return 0 ;; esac
    case "$_mo" in 2 | 3 | 6 | 7) return 0 ;; esac
    return 1
}

# path_is_root_secure <path> — the shell half of the same predicate the Go side
# applies (internal/gateway/system_tool.IsRootSecure): a regular file owned by
# uid 0, not group- or world-writable, reachable only through directories that
# are themselves root-owned and unwritable by non-root, all the way to /.
#
# The ancestor walk is the load-bearing half. A root-owned binary inside a
# user-writable directory can be unlinked and replaced by that user, after which
# root execs their file — so checking the leaf alone proves nothing.
path_is_root_secure() {
    _rs_p="$1"
    [ -f "$_rs_p" ] || return 1
    [ "$(stat_uid "$_rs_p")" = 0 ] || return 1
    if mode_allows_nonroot_write "$(stat_mode "$_rs_p")"; then return 1; fi
    _rs_d="$(dirname "$_rs_p")"
    while :; do
        [ -d "$_rs_d" ] || return 1
        [ "$(stat_uid "$_rs_d")" = 0 ] || return 1
        if mode_allows_nonroot_write "$(stat_mode "$_rs_d")"; then return 1; fi
        _rs_parent="$(dirname "$_rs_d")"
        [ "$_rs_parent" != "$_rs_d" ] || break
        _rs_d="$_rs_parent"
    done
    return 0
}

# ---------------------------------------------------------------------------
# root_bin_source <name> — where this run's copy of a privileged binary comes
# from: the unzipped bundle when there is one (fresh + update modes place
# binaries), otherwise the per-user copy already on disk.
#
# The second source is what converges a host installed under 0.2.0: that host has
# no bundle when `burrowee gateway service install` re-runs the kept installer,
# but it does have the binaries in $BIN_DIR, and copying them into the root-owned
# tree is exactly the repair. Falling back to a copy already in $LIBEXEC_DIR
# keeps a units-only run started FROM that tree (the updater's offline reinstall)
# from having nothing to name.
# ---------------------------------------------------------------------------
root_bin_source() {
    for _rbs in "./$1" "$BIN_DIR/$1" "$LIBEXEC_DIR/$1"; do
        if [ -f "$_rbs" ]; then echo "$_rbs"; return 0; fi
    done
    echo ""
}

# ---------------------------------------------------------------------------
# ensure_root_exec_surface — place every root-execed artifact under
# $LIBEXEC_DIR, root-owned, and PROVE it before any unit is allowed to name it.
# Non-zero means no unit may be written this run.
#
# Called from render_units rather than from each mode, so there is exactly one
# place where "the units are about to name these paths" and "these paths are
# safe" are decided together. Writing a unit and verifying its target in two
# different functions is how the two drift apart.
# ---------------------------------------------------------------------------
ensure_root_exec_surface() {
    run_root mkdir -p "$LIBEXEC_DIR" || return 1
    # chown/chmod are best-effort: a tree root already established correctly
    # needs neither, and re-tightening one somebody else owns is not this
    # installer's call. The verification below is what decides, not these.
    run_root chown 0:0 "$LIBEXEC_DIR" 2>/dev/null || true
    run_root chmod 0755 "$LIBEXEC_DIR" 2>/dev/null || true

    for _reb in $ROOT_BINS; do
        _reb_src="$(root_bin_source "$_reb")"
        if [ -z "$_reb_src" ]; then
            echo "error: no copy of $_reb to place in $LIBEXEC_DIR — refusing to write a unit naming it." >&2
            return 1
        fi
        # Identical content is a no-op, so a steady-state refresh needs no sudo
        # at all — and it is also what keeps a run started FROM $LIBEXEC_DIR from
        # asking `install` to copy a file onto itself.
        if [ -f "$LIBEXEC_DIR/$_reb" ] && cmp -s "$_reb_src" "$LIBEXEC_DIR/$_reb"; then continue; fi
        run_root /usr/bin/install -m 0755 "$_reb_src" "$LIBEXEC_DIR/$_reb" || return 1
        if [ "$(uname -s)" = "Darwin" ]; then
            run_root xattr -d com.apple.quarantine "$LIBEXEC_DIR/$_reb" 2>/dev/null || true
        fi
    done

    # This script and its migrations, so the root updater's offline reinstall has
    # a root-owned installer to exec. The per-user copy at $GW_HOME stays too
    # (keep_installer_copy) — a host with no system install has nothing else to
    # re-run — but root never runs that one.
    if [ ! -f "$LIBEXEC_DIR/install.sh" ] || ! cmp -s "$0" "$LIBEXEC_DIR/install.sh"; then
        run_root /usr/bin/install -m 0755 "$0" "$LIBEXEC_DIR/install.sh" || return 1
    fi
    _reb_migrations="$(dirname "$0")/migrations"
    if [ -d "$_reb_migrations" ] && [ "$_reb_migrations" != "$LIBEXEC_DIR/migrations" ]; then
        run_root mkdir -p "$LIBEXEC_DIR/migrations" || return 1
        for _reb_m in "$_reb_migrations"/*.sh; do
            [ -f "$_reb_m" ] || continue
            run_root /usr/bin/install -m 0755 "$_reb_m" "$LIBEXEC_DIR/migrations/" || return 1
        done
    fi

    verify_root_exec_surface
}

# ---------------------------------------------------------------------------
# verify_root_exec_surface — refuse when anything a unit is about to name, or
# that the root updater will exec, is not root-owned all the way to /.
#
# This is the check that makes the placement above meaningful rather than
# decorative. /usr/local is root-owned on a modern macOS and on every Linux, but
# it is not GUARANTEED to be: a host where a package manager chowned it would
# otherwise get a root-scheme unit pointing into a tree its owner can rewrite —
# the identical vulnerability, one directory over.
# ---------------------------------------------------------------------------
verify_root_exec_surface() {
    if ! have_real_root; then
        echo "note: this run never reached uid 0, so the ownership of $LIBEXEC_DIR" >&2
        echo "note: cannot be asserted — skipping the root-secure check." >&2
        return 0
    fi
    for _vre in $ROOT_BINS install.sh; do
        if ! path_is_root_secure "$LIBEXEC_DIR/$_vre"; then
            echo "error: $LIBEXEC_DIR/$_vre is not root-owned and unwritable all the way to /." >&2
            echo "error: refusing to install a service that runs as root out of a path a" >&2
            echo "error: non-root user could replace." >&2
            echo "hint: check the ownership and modes of $LIBEXEC_DIR and every directory above it;" >&2
            echo "hint: each must be owned by root and not group- or world-writable." >&2
            return 1
        fi
    done
}

# ---------------------------------------------------------------------------
# Single system slot: unit ownership + cross-user override consent.
# ---------------------------------------------------------------------------
core_unit_path() {
    case "$(uname -s)" in
    Darwin) echo "$LAUNCHD_DIR/com.burrowee.gateway.plist" ;;
    *)      echo "$SYSTEMD_DIR/burrowee-gateway.service" ;;
    esac
}

# unit_owner <file> — the run-as user recorded in an existing unit file
# (plist UserName / systemd User=). Empty when absent or unowned. Mirrors the
# Go side's UnitOwner so both unit-writers agree on slot ownership.
#
# Every unit this installer writes is now root-scheme and carries NO such
# field, so an empty answer means "root-owned, current scheme" — a FREE slot,
# not an unknown one. Only a legacy per-user unit names an owner, which is what
# makes the consent prompt below fire on exactly the case that still needs it:
# taking over the pre-split service of a different user.
unit_owner() {
    [ -f "$1" ] || { echo ""; return 0; }
    case "$1" in
    *.plist) sed -n 's|.*<key>UserName</key><string>\([^<]*\)</string>.*|\1|p' "$1" | head -n 1 ;;
    *)       sed -n 's|^User=\(.*\)$|\1|p' "$1" | head -n 1 ;;
    esac
}

# check_service_override — when the existing system unit belongs to a
# DIFFERENT user, require consent before replacing it: the force env, or a
# /dev/tty prompt defaulting to abort. Non-interactive without the env aborts.
check_service_override() {
    _owner="$(unit_owner "$(core_unit_path)")"
    if [ -z "$_owner" ] || [ "$_owner" = "$SERVICE_USER" ]; then return 0; fi
    if [ -n "${BURROWEE_FORCE_SERVICE_OVERRIDE:-}" ]; then
        echo "overriding gateway service previously installed for user '$_owner' (BURROWEE_FORCE_SERVICE_OVERRIDE)"
        return 0
    fi
    if has_tty; then
        printf "gateway service is currently installed for user '%s'. Override it for '%s'? [y/N] " "$_owner" "$SERVICE_USER" >/dev/tty
        _answer=''
        IFS= read -r _answer </dev/tty || _answer=''
        case "$_answer" in
        y|Y|yes|YES) return 0 ;;
        esac
    fi
    echo "error: the gateway system service belongs to user '$_owner' — aborting." >&2
    echo "hint: re-run with BURROWEE_FORCE_SERVICE_OVERRIDE=1 (or 'burrowee gateway service install --force-service-override') to take it over." >&2
    exit 1
}

# ---------------------------------------------------------------------------
# remove_legacy_user_units — tear down the per-user units this installer wrote
# before the system-level model (launchd gui agents / systemd --user).
# Migration is best-effort: every step tolerates "was never installed".
# ---------------------------------------------------------------------------
remove_legacy_user_units() {
    case "$(uname -s)" in
    Darwin)
        for _label in com.burrowee.gateway com.burrowee.gateway.updater org.burrowee.gateway; do
            launchctl bootout "gui/$(id -u)/$_label" 2>/dev/null || true
            rm -f "$HOME/Library/LaunchAgents/$_label.plist"
        done
        ;;
    Linux)
        systemctl --user disable --now burrowee-gateway.service 2>/dev/null || true
        systemctl --user disable --now burrowee-gateway-updater.service 2>/dev/null || true
        rm -f "$HOME/.config/systemd/user/burrowee-gateway.service" \
              "$HOME/.config/systemd/user/burrowee-gateway-updater.service"
        systemctl --user daemon-reload 2>/dev/null || true
        ;;
    esac
}

# ---------------------------------------------------------------------------
# place_unit <rendered-temp-file> <dst> — install a rendered unit at its
# system path as root, only when content differs (a no-op refresh never needs
# sudo). Must stay content-identical with the Go side's unit writers.
# ---------------------------------------------------------------------------
place_unit() {
    if [ -f "$2" ] && cmp -s "$1" "$2"; then
        rm -f "$1"
        echo "service unit: $2 (unchanged)"
        return 0
    fi
    [ -d "$(dirname "$2")" ] || run_root mkdir -p "$(dirname "$2")" || { rm -f "$1"; return 1; }
    run_root /usr/bin/install -m 0644 "$1" "$2" || { rm -f "$1"; return 1; }
    rm -f "$1"
    echo "service unit: $2"
}

# ---------------------------------------------------------------------------
# ensure_system_log_dir — pre-create the units' log directory under the SYSTEM
# data root, as root.
#
# launchd applies StandardOutPath at exec, so a missing parent is not a log
# that appears late — it is a daemon that fails to spawn. Creation goes through
# run_root because a NON-ROOT process must never create the root daemon's data
# root: on a host where /usr/local/var is writable by the installing user
# (Intel macOS, where Homebrew chowns it) an unprivileged mkdir succeeds and
# leaves the root daemon's gateway.db and register/console sockets inside a
# directory that user fully controls.
#
# 0700 is set explicitly, and only on the directories this created: mkdir -p
# applies the process umask (0755 on a typical host, which would leave the
# store world-readable), and re-tightening a root somebody else already
# established is not this installer's call. Never fatal — the daemon creates
# the tree on first start, so a missing sudo costs a log file, not an install.
# ---------------------------------------------------------------------------
ensure_system_log_dir() {
    if [ -d "$SYS_LOG_DIR" ]; then return 0; fi
    _data_root_existed=0
    if [ -d "$SYS_DATA_DIR" ]; then _data_root_existed=1; fi
    if ! run_root mkdir -p "$SYS_LOG_DIR"; then
        echo "note: could not create $SYS_LOG_DIR (needs root) — the gateway creates it on first start" >&2
        return 0
    fi
    if [ "$_data_root_existed" = 0 ]; then
        run_root chmod 0700 "$SYS_DATA_DIR" 2>/dev/null || true
    fi
    run_root chmod 0700 "$SYS_LOG_DIR" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# migration_runner — the path of the runner shipped beside this installer, or
# empty when this bundle carries none (a $GW_HOME self-copy from an install that
# predates migrations/, or a component zip built before the dir existed).
# ---------------------------------------------------------------------------
migration_runner() {
    _r="$(dirname "$0")/migrations/run.sh"
    if [ -f "$_r" ]; then echo "$_r"; else echo ""; fi
}

# ---------------------------------------------------------------------------
# assert_can_migrate <cli-path> — refuse, BEFORE anything on this host has been
# written, when the migration this bundle carries could not complete.
#
# The runner calls `burrowee-gateway-cli migrate` and probes the INSTALLED cli
# for that verb (migrations/run.sh: cli_supports_migrate). The verb arrived
# after 0.1.115, so on a live 0.1.115 host the cli on disk does not have it.
#
# Discovering that from inside the runner is far too late. install.sh exits 1
# and records no version, so the CALLER reports a failed update — but by then
# the binaries have been swapped and render_units has already written the
# root-scheme units to /Library/LaunchDaemons. Nothing removes them. On the next
# reboot launchd bootstraps the root daemon against an empty system config root,
# it mints a fresh relay_ed.key, and the node re-registers as a NEW node,
# orphaning its console pairing, targets and domains. A failed update that
# silently rebuilds the host's identity at the next power cycle is the worst
# outcome available, and it is reached through the "safe" branch.
#
# So the probe moves in FRONT of every write. The invariant it establishes: no
# unit file is written and no binary is swapped unless the migration is known to
# be able to complete. The caller passes the cli the runner will actually probe
# — the staged one in the bundle for the modes that place binaries (they place
# the cli too, see BINS), the installed one for units-only, which places none.
# ---------------------------------------------------------------------------
#
# migrate_cli_path — the cli the runner will actually probe, resolved in the
# runner's own order: the privileged copy first, the per-user one otherwise. The
# two must agree, or this pre-flight passes on one binary while the runner
# refuses on another.
migrate_cli_path() {
    for _mcp in "$LIBEXEC_DIR/burrowee-gateway-cli" "$BIN_DIR/burrowee-gateway-cli"; do
        if [ -x "$_mcp" ]; then echo "$_mcp"; return 0; fi
    done
    echo "$BIN_DIR/burrowee-gateway-cli"
}

assert_can_migrate() {
    if [ -z "$(migration_runner)" ]; then return 0; fi
    if [ -x "$1" ] && "$1" migrate --help >/dev/null 2>&1; then return 0; fi
    echo "error: this release's state migration needs 'burrowee-gateway-cli migrate'," >&2
    echo "error: and $1 does not provide it — refusing before anything is changed." >&2
    echo "hint: nothing has been touched: no binary was replaced and no service unit written." >&2
    echo "hint: install the current release first (it ships a cli that carries the verb):" >&2
    echo "hint:   curl -fsSL https://release.burrowee.com/gateway/install.sh | sh" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# migration_sudo — the elevation command handed to the runner, following THIS
# script's own root policy (run_root): a prompting `sudo` only when there is a
# controlling tty to prompt on, `sudo -n` otherwise. An explicit SUDO from the
# caller wins, so the updater's own seam still reaches the runner.
#
# The documented install flow is `curl … | sh`, where stdin is the pipe. A bare
# `sudo` there fails with "no tty present and no askpass program" — and it fails
# AFTER the runner has stopped the gateway, with none of run_root's hint text.
# ---------------------------------------------------------------------------
migration_sudo() {
    if [ -n "${SUDO:-}" ]; then echo "$SUDO"; return 0; fi
    if has_tty; then echo "sudo"; else echo "sudo -n"; fi
}

# ---------------------------------------------------------------------------
# record_installed_version <version> — write the migration ladder's version
# anchor at $GW_HOME/.installed-version.
#
# The runner gates each migration on `installed_version < target` and falls back
# to the migration's own --applies probe only when NOTHING is recorded. Leaving
# the anchor unwritten is therefore not a safe default: it routes every host to
# the path the runner's own header calls exceptional, and any future migration
# that cannot recognise its precondition structurally silently never runs.
#
# The version may arrive as the release TAG, which carries a "<component>/"
# prefix (gateway/v0.1.115.2026.08.06.d0d79ec6). The runner reads dot-separated
# fields as numbers, so "gateway/v0" is non-numeric and resolves the whole
# version to 0.0.0 — which would make a freshly-installed 0.2.x host look older
# than every migration ever written. Strip the prefix here, where the shape is
# known; the runner already strips a leading "v".
#
# NOTE for the gateway repo: gateway/update.sh (the console-push path) still has
# no writer for this file, so a host updated only by push keeps whatever anchor
# its last install.sh run left. That half belongs to the gateway repo — see the
# platform review's H8.
# ---------------------------------------------------------------------------
#
# It is written to BOTH trees, and they answer different questions. $GW_HOME's
# copy is the migration ladder's anchor — run.sh reads it and it describes the
# per-user tree the rungs migrate FROM. $LIBEXEC_DIR's copy is the updater's:
# core's local-update path reads <component home>/.installed-version to decide
# whether an install is already current, and on a root-scheme host that home is
# now the privileged tree. One writer for both keeps them from disagreeing.
record_installed_version() {
    _ver="${1##*/}"
    if [ -z "$_ver" ]; then return 0; fi
    mkdir -p "$GW_HOME"
    printf '%s\n' "$_ver" > "$GW_HOME/.installed-version"
    if [ -d "$LIBEXEC_DIR" ]; then
        printf '%s\n' "$_ver" | run_root tee "$LIBEXEC_DIR/.installed-version" >/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# migrate_from_legacy — run the release's migrations/run.sh, which walks every
# migration in its ledger and runs the ones this host has not reached yet.
#
# The runner owns the whole decision: it resolves the installed version, gates
# each migration on `installed_ver < target`, runs them oldest first, and records
# each one that completes. It is a no-op unless one applies, so this may be
# called unconditionally.
#
# Called BEFORE any step that starts the gateway, never after: the runner stops
# the gateway so its state is at rest while it is copied, and leaves the restart
# to us.
#
# It places no units and knows nothing about them. Unit placement is render_units
# + load_units below, on the paths that have them; reaching the units from inside
# a migration would mean re-entering this script via `service install` and
# booting out whichever supervisor is running it.
#
# MIGRATED is set when the runner reports exit 2 — "migrations ran, the gateway is
# stopped" — so a mode with no load_units step can say so rather than leaving the
# operator to discover a stopped service.
#
# Exit 3 is exit 2 plus "and the receipt could not be written". The migration
# ran, so the gateway is stopped exactly as for 2; what differs is that the only
# surviving gate on re-running it is the version anchor. Recording the version
# there would convert a receipt-gated, re-runnable migration into a
# version-gated never-again one, so MIGRATE_UNRECORDED suppresses the write and
# the next install re-runs the migration (every migration is idempotent).
#
# Any other non-zero is FATAL. Carrying on would start the new root units against
# a config root with no identity: the daemon then either refuses to start or mints
# a fresh one, and a new relay_ed.key re-registers this host as a NEW node,
# orphaning its console pairing, targets and domains.
#
# Not found is not an error: BURROWEE_UNITS_ONLY can run from $GW_HOME's
# self-copy, and an install predating the migrations/ dir has none beside it.
# ---------------------------------------------------------------------------
MIGRATED=0
MIGRATE_UNRECORDED=0
migrate_from_legacy() {
    _runner="$(migration_runner)"
    if [ -z "$_runner" ]; then return 0; fi
    # The privileged copies go in BEFORE the runner, not with the units after it.
    # The runner shells to burrowee-gateway-cli AS ROOT (v1_to_v2.sh's `elevate
    # "$CLI" migrate`), and on the console-push path nobody is watching — so a
    # migration that could only reach a per-user cli is the same escalation the
    # per-user ExecStart was. Both the runner and this script resolve the cli out
    # of $LIBEXEC_DIR first, which is what this call makes true.
    if ! ensure_root_exec_surface; then
        echo "error: could not establish the root-owned $LIBEXEC_DIR — refusing to run a" >&2
        echo "error: state migration that would exec a per-user binary as root." >&2
        echo "hint: nothing has been migrated; fix the cause reported above and re-run." >&2
        exit 1
    fi
    set +e
    GW_HOME="$GW_HOME" \
        PREFIX="${PREFIX:-$HOME/.local}" \
        BURROWEE_SYSTEM_CONFIG_DIR="$SYS_CONFIG_DIR" \
        BURROWEE_SYSTEM_DATA_DIR="$SYS_DATA_DIR" \
        SUDO="$(migration_sudo)" \
        sh "$_runner"
    _rc=$?
    set -e
    case "$_rc" in
    0) ;;
    2) MIGRATED=1 ;;
    3) MIGRATED=1; MIGRATE_UNRECORDED=1 ;;
    *)
        echo "error: a state migration failed — stopping before the service is started." >&2
        echo "hint: $GW_HOME is untouched; fix the cause reported above and re-run this installer." >&2
        exit 1
        ;;
    esac
}

# ---------------------------------------------------------------------------
# report_unrecorded_migration — say that a migration completed without its
# receipt, and that the version anchor was withheld on purpose so it runs again.
# Every mode that calls migrate_from_legacy calls this after it.
# ---------------------------------------------------------------------------
report_unrecorded_migration() {
    if [ "$MIGRATE_UNRECORDED" != "1" ]; then return 0; fi
    echo "note: a migration completed but its receipt could not be written." >&2
    echo "note: the installed version is deliberately NOT recorded, so the next install" >&2
    echo "note: re-runs the migration (they are idempotent) rather than gating it off" >&2
    echo "note: on a version number with no receipt behind it." >&2
}

# ---------------------------------------------------------------------------
# keep_installer_copy — keep this installer AND the migrations beside it under
# $GW_HOME, so a later `service install` can re-render units and run any pending
# migration without a fresh download.
#
# Both, in every mode. install.sh resolves the runner relative to its OWN path, so
# a $GW_HOME holding install.sh without migrations/ is an installer that silently
# cannot migrate — and `burrowee gateway service install` is the remedy this
# script points operators at.
# ---------------------------------------------------------------------------
keep_installer_copy() {
    mkdir -p "$GW_HOME"
    cp "$0" "$GW_HOME/install.sh" 2>/dev/null || true
    _src_migrations="$(dirname "$0")/migrations"
    if [ -d "$_src_migrations" ]; then
        mkdir -p "$GW_HOME/migrations"
        if ! cp "$_src_migrations"/*.sh "$GW_HOME/migrations/" 2>/dev/null; then
            echo "note: could not keep a copy of migrations/ at $GW_HOME — a later" >&2
            echo "note: 'burrowee gateway service install' will not be able to migrate." >&2
        fi
    fi
}

# ---------------------------------------------------------------------------
# render_units — write both SYSTEM service unit FILES for the host init
# system (as root, via place_unit). Does NOT start, stop, or reload any live
# services. Call load_units after render_units when a live reload is desired
# (fresh install / units-only).
#
# It places the PRIVILEGED BINARIES first and returns non-zero when it could not
# prove them root-owned, because the alternative is worse than no units at all:
# a unit is durable, the supervisor execs what it names as root at every boot,
# and nothing rewrites it until an install runs again. There is no retry that
# undoes a bad one. Every caller already handles a non-zero return — the two
# install paths abort under `set -e`, update mode prints its "run service
# install" note — so the refusal costs a host its units, never its identity.
# ---------------------------------------------------------------------------
render_units() {
    ensure_root_exec_surface || return 1
    case "$(uname -s)" in
    Darwin)
        ensure_system_log_dir

        # Core unit. KeepAlive.PathState restarts the daemon after ANY exit
        # while the binary exists (a graceful SIGTERM exit is the
        # update-restart mechanism) and waits quietly when the volume holding
        # the binary is not mounted yet. WorkingDirectory=/tmp keeps launchd
        # out of possibly TCC-protected paths.
        _tmp_unit="$(mktemp)"
        cat > "$_tmp_unit" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.burrowee.gateway</string>
  <key>ProgramArguments</key><array><string>$LIBEXEC_DIR/burrowee-gateway</string><string>--no-open</string><string>--config-dir</string><string>$SYS_CONFIG_DIR</string><string>--data-dir</string><string>$SYS_DATA_DIR</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>WorkingDirectory</key><string>/tmp</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>PathState</key><dict><key>$LIBEXEC_DIR/burrowee-gateway</key><true/></dict></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$SYS_LOG_DIR/gateway.log</string>
  <key>StandardErrorPath</key><string>$SYS_LOG_DIR/gateway.err.log</string>
</dict></plist>
EOF
        place_unit "$_tmp_unit" "$LAUNCHD_DIR/com.burrowee.gateway.plist"

        # Updater unit. No path flags: the updater agent resolves its own roots,
        # which already default to the system pair under root's euid — the same
        # defaulting the core unit's flags only make explicit.
        _tmp_unit="$(mktemp)"
        cat > "$_tmp_unit" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.burrowee.gateway.updater</string>
  <key>ProgramArguments</key><array><string>$LIBEXEC_DIR/burrowee-gateway-updater</string><string>run</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>WorkingDirectory</key><string>/tmp</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>PathState</key><dict><key>$LIBEXEC_DIR/burrowee-gateway-updater</key><true/></dict></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$SYS_LOG_DIR/updater.log</string>
  <key>StandardErrorPath</key><string>$SYS_LOG_DIR/updater.err.log</string>
</dict></plist>
EOF
        place_unit "$_tmp_unit" "$LAUNCHD_DIR/com.burrowee.gateway.updater.plist"
        ;;

    Linux)
        ensure_system_log_dir

        # Core unit. Restart=always (not on-failure): a graceful SIGTERM exit
        # must still restart — that is the update-restart mechanism. No User=/
        # Group=/Environment=HOME=: the daemon runs as root and takes both path
        # roots as flags, so the unit body carries nothing caller-specific.
        _tmp_unit="$(mktemp)"
        cat > "$_tmp_unit" <<EOF
[Unit]
Description=burrowee-gateway
After=network-online.target

[Service]
ExecStart=$LIBEXEC_DIR/burrowee-gateway --no-open --config-dir $SYS_CONFIG_DIR --data-dir $SYS_DATA_DIR
Restart=always
RestartSec=2
TimeoutStopSec=330

[Install]
WantedBy=multi-user.target
EOF
        place_unit "$_tmp_unit" "$SYSTEMD_DIR/burrowee-gateway.service"

        # Updater unit. No path flags: the updater agent resolves its own roots,
        # which already default to the system pair under root's euid — the same
        # defaulting the core unit's flags only make explicit.
        _tmp_unit="$(mktemp)"
        cat > "$_tmp_unit" <<EOF
[Unit]
Description=burrowee-gateway-updater
After=network-online.target

[Service]
ExecStart=$LIBEXEC_DIR/burrowee-gateway-updater run
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
        place_unit "$_tmp_unit" "$SYSTEMD_DIR/burrowee-gateway-updater.service"
        ;;

    *)
        echo "warning: unsupported OS — skipping service unit installation" >&2
        ;;
    esac
}

# ---------------------------------------------------------------------------
# load_units — (re)load the rendered SYSTEM service units (root). Separated
# from render_units so update mode can refresh the unit FILES without
# restarting services (the updater restarts the kernel out-of-band; restarting
# the updater here would bootout the very process running this script — see
# the design doc). All steps are best-effort so a supervisor-less host (e.g. a
# container) still completes the install; the unit files on disk are the
# durable outcome.
#
# BURROWEE_NO_RESTART=1 stages the units (installed/enabled) without starting
# or restarting anything already running — the local-stage counterpart to the
# gateway's `update`/`reinstall` verbs without --auto (design §4.4). Fresh
# install onto a host with nothing running yet needs at least an initial
# bootstrap/enable so the service can be started later; only the "kick a
# possibly-already-running unit" steps are skipped.
# ---------------------------------------------------------------------------
load_units() {
    case "$(uname -s)" in
    Darwin)
        if [ -n "${BURROWEE_NO_RESTART:-}" ]; then
            # Stage only: bootstrap lays each unit in place (and fails harmlessly
            # for an already-loaded label) without booting anything out from
            # under a running instance. The two branches are exclusive — running
            # bootstrap before the bootout+bootstrap pair would start, stop, then
            # restart the service on every fresh install.
            run_root launchctl bootstrap system "$LAUNCHD_DIR/com.burrowee.gateway.plist"         2>/dev/null || true
            run_root launchctl bootstrap system "$LAUNCHD_DIR/com.burrowee.gateway.updater.plist" 2>/dev/null || true
            echo "note: BURROWEE_NO_RESTART set — units staged (not restarted)" >&2
        else
            run_root launchctl bootout   "system/com.burrowee.gateway"          2>/dev/null || true
            run_root launchctl bootstrap system "$LAUNCHD_DIR/com.burrowee.gateway.plist"         2>/dev/null || true
            run_root launchctl bootout   "system/com.burrowee.gateway.updater"  2>/dev/null || true
            run_root launchctl bootstrap system "$LAUNCHD_DIR/com.burrowee.gateway.updater.plist" 2>/dev/null || true
        fi
        ;;
    Linux)
        run_root systemctl daemon-reload 2>/dev/null || true
        if [ -n "${BURROWEE_NO_RESTART:-}" ]; then
            run_root systemctl enable burrowee-gateway.service         2>/dev/null || true
            run_root systemctl enable burrowee-gateway-updater.service 2>/dev/null || true
            echo "note: BURROWEE_NO_RESTART set — units staged (not restarted)" >&2
        else
            run_root systemctl enable --now burrowee-gateway.service         2>/dev/null || true
            run_root systemctl enable --now burrowee-gateway-updater.service 2>/dev/null || true
            # A reinstall over an already-running (possibly stale) updater must advance
            # it to the freshly-installed binary — `enable --now` no-ops a running unit,
            # so restart it explicitly. Otherwise the stale updater keeps running old
            # code and future pushes deadlock. (load_units is never called on the
            # updater's own push path — BURROWEE_UPDATE renders units without loading
            # them — so this can never self-kill. The Darwin branch above already
            # advances the updater via its bootout+bootstrap.)
            run_root systemctl restart burrowee-gateway-updater.service 2>/dev/null || true
        fi
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
    # First, ahead of the consent prompt and every write: this mode places no
    # binaries at all, so the cli the runner will probe is the one already on
    # disk. If it cannot migrate, render_units below would leave root-scheme
    # units on a host whose state never moved.
    assert_can_migrate "$(migrate_cli_path)"
    check_service_override
    remove_legacy_user_units
    # Before render_units as well as before load_units. Before load_units because
    # the migration stops the gateway to copy its store at rest and load_units is
    # what starts it again; before render_units because a migration that fails for
    # ANY reason exits this script — and a root-scheme unit left on disk by a run
    # that then aborted is bootstrapped by launchd at the next reboot regardless,
    # against a config root the migration never populated.
    migrate_from_legacy
    render_units
    load_units
    report_unrecorded_migration
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
    # The outer bootstrap re-runs this script in update mode (the `--force` full
    # reinstall) with the resolved release tag in BURROWEE_VERSION and NO argv of
    # its own, so that path recorded no version at all. Argv wins where both are
    # present; record_installed_version normalises either shape.
    if [ -z "$_install_version" ]; then _install_version="${BURROWEE_VERSION:-}"; fi

    # Whose slot is it? Answered up front, because it decides both whether a
    # migration will be attempted at all (and so whether the pre-flight below
    # applies) and whether the version may be recorded at the end.
    _slot_owner="$(unit_owner "$(core_unit_path)")"
    _own_slot=0
    if [ -z "$_slot_owner" ] || [ "$_slot_owner" = "$SERVICE_USER" ]; then _own_slot=1; fi

    mkdir -p "$BIN_DIR"

    # Phase 1: detect which binaries changed. BURROWEE_FORCE=1 (set by the Go
    # side only on `gateway update --force`) forces every serve binary to be
    # re-placed regardless of sha256 — a --force onto the already-installed
    # version has byte-identical binaries, so without this it would place
    # nothing and the operator's "reinstall completely" would be a no-op.
    #
    # burrowee-gateway-cli IS placed here, and that is a change from the shape
    # that shipped: the migration calls `burrowee-gateway-cli migrate`, and the
    # runner probes the INSTALLED cli for the verb. Leaving a 0.1.115 cli on
    # disk while swapping everything around it guaranteed that probe would fail
    # — with the units already written. gateway/update.sh, the other half of the
    # same update, has always carried the cli in its BINS; the two paths now
    # agree. Only burrowee-gateway-updater stays excluded: it is on its own
    # track, and replacing the binary a running updater is executing from
    # mid-update is what that exclusion exists to prevent.
    CHANGED=""
    for b in $BINS; do
        [ "$b" = "burrowee-gateway-updater" ] && continue   # its own update track: never replaced from inside an update it is running
        _staged="./$b"
        [ -f "$_staged" ] || { echo "missing $b in bundle" >&2; exit 1; }
        _staged_sum="$(sha256_of "$_staged")"
        _cur_sum=""
        if [ -f "$BIN_DIR/$b" ]; then
            _cur_sum="$(sha256_of "$BIN_DIR/$b")"
        fi
        if [ -n "${BURROWEE_FORCE:-}" ] || [ "$_staged_sum" != "$_cur_sum" ]; then
            CHANGED="${CHANGED:+$CHANGED }$b"
        fi
    done

    # Phase 1b — the pre-flight, deliberately between detection (which writes
    # nothing) and the first write. Phase 1 has already proved every staged
    # binary exists, so a refusal here is about the verb, not a missing file.
    #
    # Skipped when the slot belongs to another user: the branch below then
    # defers the migration entirely, so there is nothing to be unable to
    # complete, and refusing would block a binary swap that is independently
    # correct.
    if [ "$_own_slot" = "1" ]; then
        assert_can_migrate "./burrowee-gateway-cli"
    fi

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

    # The kept copy FIRST, before the migration runs. `service install` re-runs
    # $GW_HOME/install.sh, so a stale copy there is a stale unit-writer; and the
    # runner is resolved beside whichever install.sh is executing, so the copy is
    # also what makes a later `service install` able to migrate at all.
    keep_installer_copy

    # Migrate, THEN refresh the system unit FILES only — never load/restart them
    # here (the updater restarts the kernel out-of-band; loading would bootout the
    # very process running this script), never touch another user's slot, and
    # never fail the binary swap for lack of sudo: a unit refresh can always
    # happen later via 'burrowee gateway service install'.
    #
    # The migration comes first because a failed one exits this script, and a
    # root-scheme unit already on disk is bootstrapped by launchd at the next
    # reboot whatever this run reported — against a config root the migration
    # never populated. Leaving the OLD units in place is strictly better: they
    # point at a tree that still holds the host's identity.
    if [ "$_own_slot" = "1" ]; then
        # Inside this branch, not beside it: a migration claims whose identity the
        # root daemon adopts, and on a slot belonging to someone else that claim
        # would be wrong in the one direction that cannot be undone — a
        # re-registered node under the wrong identity. Update mode has no consent
        # prompt to settle it (unlike the install paths, which run
        # check_service_override first), so it defers instead.
        migrate_from_legacy
        render_units || echo "note: service units not refreshed (needs sudo) — run 'burrowee gateway service install'" >&2

        # The version LAST, and only once everything above succeeded. Recording it
        # before the migration would mean a failed migration leaves the new version on
        # disk with the old layout still in place — after which every later run reads
        # "already up to date" and the host never migrates again. A failed migration
        # exits non-zero above, so reaching here means there is nothing pending.
        #
        # INSIDE this branch, for the same reason the migration is: the deferring
        # branch below leaves a legacy tree unmigrated, and the runner consults a
        # migration's own --applies probe only when NO version is recorded. Writing
        # the version there would hand the numeric gate sole authority over a rung
        # that never ran, permanently — a second, independent route to the node
        # re-registering under a fresh identity.
        if [ "$MIGRATE_UNRECORDED" = "0" ]; then
            record_installed_version "$_install_version"
        fi
    else
        echo "note: gateway system service belongs to user '$_slot_owner' — units not refreshed" >&2
        echo "note: not migrating either — 'burrowee gateway service install' takes the slot over first" >&2
        echo "note: and the installed version is not recorded, so the migration stays pending" >&2
    fi

    report_unrecorded_migration

    # This mode has no start step of its own; say so rather than leaving the
    # operator to find a stopped service.
    if [ "$MIGRATED" = "1" ]; then
        echo "note: a migration stopped the gateway — it starts again on the updater's restart," >&2
        echo "note: or run 'burrowee gateway restart' now." >&2
    fi

    # Final change-set line (MUST be the last stdout line).
    printf 'BURROWEE_CHANGED=%s\n' "$CHANGED"
    exit 0
fi

if [ -n "${BURROWEE_UNINSTALL:-}" ]; then
    for b in $BINS; do rm -f "$BIN_DIR/$b"; done
    echo "removed from $BIN_DIR: $BINS"

    # The privileged copies too, or an uninstall leaves root-owned binaries and a
    # root-owned installer behind for the next install to inherit without ever
    # re-verifying them. Best-effort, like every other root step here.
    if [ -d "$LIBEXEC_DIR" ]; then
        if run_root rm -rf "$LIBEXEC_DIR"; then
            echo "removed $LIBEXEC_DIR"
        else
            echo "note: could not remove $LIBEXEC_DIR (needs root) — remove it by hand" >&2
        fi
    fi

    # Remove the system service units (root) plus any legacy per-user units.
    # All best-effort: a missing unit or unavailable sudo must not stop uninstall.
    case "$(uname -s)" in
    Darwin)
        for _label in com.burrowee.gateway com.burrowee.gateway.updater; do
            if [ -f "$LAUNCHD_DIR/$_label.plist" ]; then
                run_root launchctl bootout "system/$_label" 2>/dev/null || true
                run_root rm -f "$LAUNCHD_DIR/$_label.plist" || true
            fi
        done
        ;;
    Linux)
        _removed=""
        for _unit in burrowee-gateway.service burrowee-gateway-updater.service; do
            if [ -f "$SYSTEMD_DIR/$_unit" ]; then
                run_root systemctl disable --now "$_unit" 2>/dev/null || true
                run_root rm -f "$SYSTEMD_DIR/$_unit" || true
                _removed=1
            fi
        done
        if [ -n "$_removed" ]; then
            run_root systemctl daemon-reload 2>/dev/null || true
        fi
        ;;
    esac
    remove_legacy_user_units

    exit 0
fi

# ---------------------------------------------------------------------------
# Fresh install (default mode).
# ---------------------------------------------------------------------------

# Before the first write, same invariant as update mode: this run places every
# binary including the cli, so the staged cli is the one the runner will probe.
assert_can_migrate "./burrowee-gateway-cli"

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

# Keep this installer + its migrations at $GW_HOME so subsequent `service install`
# verbs can re-render units and run a pending migration without a new download.
keep_installer_copy

# Write and load both SYSTEM service units (single-slot consent first, then
# migrate any legacy per-user units out of the way). The state migration runs
# before render_units, not between it and load_units: a failed migration exits
# here, and a root-scheme unit left behind by an aborted run is bootstrapped by
# launchd at the next reboot regardless of what this run reported.
check_service_override
remove_legacy_user_units
migrate_from_legacy
render_units
load_units
report_unrecorded_migration

# Record the ladder's version anchor here too. Fresh mode never did, which left
# the anchor written from exactly ONE place platform-wide (update mode, and only
# with --version) — so essentially every host reached a future rung through the
# runner's --applies fallback, the path its own header calls exceptional. The
# outer bootstrap passes the resolved release tag as BURROWEE_VERSION; a run
# without it (a hand-invoked inner installer) records nothing and keeps today's
# behaviour rather than inventing a version.
if [ "$MIGRATE_UNRECORDED" = "0" ]; then
    record_installed_version "${BURROWEE_VERSION:-}"
fi

# ---- first-run bootstrap (interactive only, fresh installs) -------------------
# Re-install short-circuit: if this host already holds gateway STATE it is
# already set up — never re-prompt for a setup blob. Otherwise read blob+PIN
# from the controlling terminal (stdin is the curl pipe, not a tty): prompt only
# if /dev/tty is genuinely usable (fd 3); if not (CI / detached) just print the
# next step. All tty I/O is fault-tolerant so it can never abort the install.
#
# gateway_already_set_up probes for the state itself, never for a non-empty
# $COMP_HOME. keep_installer_copy above creates that directory and writes
# install.sh + migrations/ into it a few dozen lines earlier, so "non-empty" is
# something THIS script guarantees: on a genuinely virgin host the old test
# printed "already set up — skipping setup" and the blob + PIN prompt never ran.
#
# Both layouts count. Pre-0.2.0 state lives in the per-user tree; on a migrated
# or root-installed host the identity and the store are under the SYSTEM roots
# and $COMP_HOME holds nothing but the installer copy — so a probe that looked
# only at $COMP_HOME would re-prompt a fully enrolled 0.2.x host.
gateway_already_set_up() {
    for _p in \
        "$COMP_HOME/identity/relay_ed.key" \
        "$COMP_HOME/keys/relay_ed.key" \
        "$COMP_HOME/gateway.db" \
        "$SYS_CONFIG_DIR/identity/relay_ed.key" \
        "$SYS_DATA_DIR/gateway.db"
    do
        if [ -e "$_p" ]; then return 0; fi
    done
    return 1
}

if gateway_already_set_up; then
    echo "$COMP already set up — skipping setup."
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

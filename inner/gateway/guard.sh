#!/bin/sh
# inner/gateway/guard.sh — the install guard.
#
#     guard.sh <transaction-dir>
#
# It is handed to launchd/systemd by install.sh, NOT forked from the operator's
# shell, so it has no controlling terminal and no ancestry in the session that
# is about to die. That is the entire point: on a gateway the operator reaches
# the host THROUGH the daemon this script restarts, so the restart severs the
# session, and anything still running in that session dies with it.
#
# It owns the outcome of the whole install, not just the restart, because the
# restart is not the only thing that stops the daemon: the migration ladder's
# adopt_user_tree.sh stops it too, seventeen lines earlier, to copy state at
# rest. A guard armed only for the restart would watch the wrong line.
#
# EXIT CONTRACT: 0 ok · 1 rolled-back · 2 failed.
set -eu

TXN="${1:?usage: guard.sh <transaction-dir>}"

LAUNCHCTL="${GUARD_LAUNCHCTL:-launchctl}"
SYSTEMCTL="${GUARD_SYSTEMCTL:-systemctl}"
UNAME="${GUARD_UNAME:-$(uname -s)}"
BIN_DIR="${BURROWEE_BIN_DIR:-/usr/local/bin}"
SYS_DATA_DIR="${BURROWEE_SYSTEM_DATA_DIR:-/usr/local/var/burrowee/gateway}"

# The installer copies state; a generous ceiling so a slow migration is not
# mistaken for a wedged one.
DEADLINE="${GUARD_DEADLINE:-900}"
VERIFY_CEILING="${GUARD_VERIFY_CEILING:-60}"
VERIFY_INTERVAL="${GUARD_VERIFY_INTERVAL:-2}"

LABEL=com.burrowee.gateway
UNIT=burrowee-gateway.service

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >> "$TXN/guard.log"; }
phase() { printf '%s\n' "$1" > "$TXN/.phase.tmp" && mv -f "$TXN/.phase.tmp" "$TXN/phase"; }
now() { date -u +%s; }

printf '%s\n' "$$" > "$TXN/guard.pid"
log "guard armed for $TXN"

# running_version — the version the daemon reports for ITSELF. The same oracle
# the installer's wait uses; there is deliberately no second definition of
# healthy anywhere in this system.
running_version() {
    sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$SYS_DATA_DIR/running.json" 2>/dev/null || true
}

binary_version() {
    BURROWEE_DISPATCHER_VERSION= "$BIN_DIR/burrowee-gateway" version 2>/dev/null |
        sed -n 's/.*\(v[0-9][0-9.a-z]*\).*/\1/p' | head -1
}

# restart_service — kickstart -k / systemctl restart. NEVER bootout: an
# unloaded job is supervised by nothing, so a guard that is itself killed
# between a bootout and its bootstrap would strand exactly the state this
# script exists to prevent.
restart_service() {
    case "$UNAME" in
    Darwin)
        "$LAUNCHCTL" bootstrap system "${BURROWEE_LAUNCHD_DIR:-/Library/LaunchDaemons}/$LABEL.plist" 2>/dev/null || true
        "$LAUNCHCTL" enable "system/$LABEL" 2>/dev/null || true
        "$LAUNCHCTL" kickstart -k "system/$LABEL" 2>/dev/null || true
        ;;
    Linux)
        "$SYSTEMCTL" daemon-reload 2>/dev/null || true
        "$SYSTEMCTL" enable "$UNIT" 2>/dev/null || true
        "$SYSTEMCTL" restart "$UNIT" 2>/dev/null || true
        ;;
    esac
}

# verify_serving <want> — the daemon reports <want> within the ceiling.
verify_serving() {
    _want="$1"; _waited=0
    while [ "$_waited" -lt "$VERIFY_CEILING" ]; do
        if [ "$(running_version)" = "$_want" ]; then
            log "daemon is serving $_want (after ${_waited}s)"
            return 0
        fi
        sleep "$VERIFY_INTERVAL"
        _waited=$((_waited + VERIFY_INTERVAL))
    done
    log "daemon did not report $_want within ${VERIFY_CEILING}s"
    return 1
}

rollback() {
    phase rolling-back
    log "restoring the snapshot"
    _snap="$TXN/snapshot"
    _want="$(sed -n 's/^running_version=//p' "$TXN/manifest" 2>/dev/null || true)"

    if [ -d "$_snap/bin" ]; then
        for _b in "$_snap/bin"/*; do
            [ -e "$_b" ] || continue
            cp -p "$_b" "$BIN_DIR/${_b##*/}" || log "could not restore ${_b##*/}"
        done
    fi
    case "$UNAME" in
    Darwin) _ud="${BURROWEE_LAUNCHD_DIR:-/Library/LaunchDaemons}" ;;
    Linux)  _ud="${BURROWEE_SYSTEMD_DIR:-/etc/systemd/system}" ;;
    *)      _ud="" ;;
    esac
    if [ -n "$_ud" ] && [ -d "$_snap/units" ]; then
        for _u in "$_snap/units"/*; do
            [ -e "$_u" ] || continue
            cp -p "$_u" "$_ud/${_u##*/}" || log "could not restore ${_u##*/}"
        done
    fi
    [ -d "$_snap/config" ] && cp -Rp "$_snap/config/." "${BURROWEE_SYSTEM_CONFIG_DIR:-/usr/local/etc/burrowee/gateway}/"
    [ -d "$_snap/data" ]   && cp -Rp "$_snap/data/."   "$SYS_DATA_DIR/"

    restart_service
    if [ -n "$_want" ] && verify_serving "$_want"; then
        phase rolled-back
        log "ROLLED BACK — $_want is serving again; the new build was discarded"
        exit 1
    fi
    phase failed
    log "FAILED — the rollback did not come up either; this host needs hands"
    exit 2
}

# sweep_stale_bins_via_kept_installer — run the installer's own
# sweep_stale_user_bins, the way keep_installer_copy leaves it for exactly
# this: a copy of install.sh (and migrations/) at $GW_HOME, the value
# snapshot_take recorded into the manifest because the guard, running under
# launchd/systemd rather than the invoking operator's session, has no
# reliable $HOME to resolve $GW_HOME from itself.
#
# Deliberately NOT `burrowee-gateway-cli service install`: that re-enters
# install.sh in BURROWEE_UNITS_ONLY mode, which arms a SECOND guard inside
# this one's own success path. Sourcing the kept installer reaches the one
# function this step needs without re-running any of the rest of it.
#
# Run in a subshell (`sh -c`), never dot-sourced into this shell directly:
# install.sh defines BIN_DIR, SYS_DATA_DIR and other names this script also
# uses, and dot-sourcing it here would overwrite them in place. $0 is set to
# the kept installer's own path via the trailing argument — sh has no other
# portable way to steer it — so install.sh's own `$(dirname "$0")/migrations`
# resolution (stale_sweep_lib) finds the migrations/ copy keep_installer_copy
# kept right beside it.
#
# Must run only AFTER a verified restart — see this file's header and
# sweep_stale_user_bins' own comment in install.sh: it deletes per-user
# binaries, and until the daemon has actually advanced onto the loaded units,
# a still-running per-user process may still name one.
sweep_stale_bins_via_kept_installer() {
    _gw_home="$(sed -n 's/^gw_home=//p' "$TXN/manifest" 2>/dev/null || true)"
    if [ -z "$_gw_home" ] || [ ! -f "$_gw_home/install.sh" ]; then
        log "no kept installer at '${_gw_home:-<unset>}/install.sh' — skipping the stale-bin sweep"
        return 0
    fi
    if BURROWEE_SOURCE_ONLY=1 sh -c '. "$0"; sweep_stale_user_bins' "$_gw_home/install.sh" \
        >> "$TXN/guard.log" 2>&1
    then
        log "stale-bin sweep ran via $_gw_home/install.sh"
    else
        log "stale-bin sweep failed (via $_gw_home/install.sh) — continuing"
    fi
}

# advance_updater — start (or restart) the updater unit. load_units used to do
# this in the foreground; Task 7 removed load_units from the fresh-install
# path entirely, which left the updater unit RENDERED but never started on a
# fresh install. This is what restores it, after the serve daemon itself is
# already proven up.
#
# Safe to bootout on Darwin, unlike the serve label: nothing routes through
# the updater, so a guard killed mid-bootout strands nothing an operator needs
# to reach the host.
advance_updater() {
    case "$UNAME" in
    Darwin)
        "$LAUNCHCTL" bootout "system/$LABEL.updater" 2>/dev/null || true
        "$LAUNCHCTL" bootstrap system "${BURROWEE_LAUNCHD_DIR:-/Library/LaunchDaemons}/$LABEL.updater.plist" 2>/dev/null || true
        "$LAUNCHCTL" enable "system/$LABEL.updater" 2>/dev/null || true
        "$LAUNCHCTL" kickstart -k "system/$LABEL.updater" 2>/dev/null || true
        ;;
    Linux)
        "$SYSTEMCTL" enable --now burrowee-gateway-updater.service 2>/dev/null || true
        "$SYSTEMCTL" restart burrowee-gateway-updater.service 2>/dev/null || true
        ;;
    esac
    log "updater advanced"
}

# apply_retention — keep this transaction and the two before it. A snapshot is
# a full copy of the state tree, so an unbounded ring of them is an unbounded
# disk cost on a host nobody is watching. Transaction directories are named by
# a UTC timestamp (txn_begin's TXN_STAMP), which sorts lexically, so `sort`
# orders them chronologically with no extra bookkeeping.
#
# Deliberately not `head -n -3`: that negative-count form is a GNU extension
# with no guaranteed BSD equivalent, and this script ships to real Darwin
# hosts (the `head` on the guard's own platform, not just the suite's CI
# box). Counted and sliced by hand instead, entirely in POSIX sh.
apply_retention() {
    _base="$SYS_DATA_DIR/install"
    [ -d "$_base" ] || return 0
    _total="$(ls -1 "$_base" 2>/dev/null | wc -l | tr -d ' ')"
    _drop=$((_total - 3))
    if [ "$_drop" -le 0 ]; then
        log "snapshot retention: $_total kept, nothing to prune"
        return 0
    fi
    _i=0
    ls -1 "$_base" 2>/dev/null | sort | while read -r _old; do
        _i=$((_i + 1))
        [ "$_i" -le "$_drop" ] && [ -n "$_old" ] && rm -rf "$_base/$_old"
    done
    log "snapshot retention applied ($_drop pruned, 3 kept)"
}

do_restart() {
    phase restarting
    _want="$(binary_version)"
    if [ -z "$_want" ]; then
        log "could not read the new binary's version stamp — treating as a failed restart"
        rollback
    fi
    log "restarting $LABEL, expecting $_want"
    restart_service
    if verify_serving "$_want"; then
        phase ok
        log "OK — $_want is serving"

        # Post-success work the installer used to do after load_units, moved
        # here because a severed session skipped all of it.
        sweep_stale_bins_via_kept_installer
        advance_updater
        apply_retention

        exit 0
    fi
    rollback
}

# ---- watch ----------------------------------------------------------------
# Three ways out, and every one of them is decided here rather than by whoever
# is still alive:
#   handoff        the installer finished its work and wants the restart
#   installer died the session was severed mid-install — the migration case
#   deadline       something is wedged; do not hold the host hostage
_ipid="$(cat "$TXN/installer.pid" 2>/dev/null || echo 0)"
_start="$(now)"
while :; do
    _p="$(cat "$TXN/phase" 2>/dev/null || echo unknown)"
    case "$_p" in
        handoff) log "installer handed off"; do_restart ;;
        ok | rolled-back | failed) log "already terminal ($_p)"; exit 0 ;;
    esac
    if [ "$_ipid" != 0 ] && ! kill -0 "$_ipid" 2>/dev/null; then
        log "installer pid $_ipid exited at phase '$_p' without handing off — rolling back"
        rollback
    fi
    if [ $(( $(now) - _start )) -ge "$DEADLINE" ]; then
        log "deadline ${DEADLINE}s exceeded at phase '$_p' — rolling back"
        rollback
    fi
    sleep 1
done

#!/bin/sh
# _shared/migrations/lib_stale_user_bins.sh — the sweep of the pre-0.2.0
# per-user copies of a component's binaries. SOURCED, never executed.
#
# NOT A RUNG. run.sh walks the LEDGER and this file is not in it; it defines
# functions and nothing else, so sourcing it has no effect on a host. It ships
# inside migrations/ because that is the directory both of its callers can
# already resolve beside themselves:
#
#   * the component's inner/<comp>/install.sh, which sources it and calls
#     remove_stale_user_bins on every install — a fresh install must not need
#     the ladder to be coherent;
#   * migrations/stale_user_bins.sh, the 0.2.0 rung, which is how the sweep
#     reaches a host the installer never ran on. THE UPDATER NEVER RUNS
#     install.sh: it swaps binaries and restarts the daemon. So before the rung
#     existed an updated host kept its stale per-user copies forever (observed
#     on a production node, 2026-08-17: the gateway daemon at
#     v0.2.0.2026.08.17 with ~/.local/bin/burrowee-gateway still on the Aug 8
#     build, and a drift row whose recommended `restart` provably could not
#     clear it).
#
# ONE FILE, because the two callers must not merely agree — every guard below
# fails silently in the safe-looking direction, so a second implementation that
# drifted would look exactly like this one right up to the deletion it got
# wrong. The rung being idempotent is what makes it safe for both to run.
#
# IT IS THE SAME FILE FOR EVERY COMPONENT, TOO. The gateway carries its own copy
# in the gateway repo (it shipped there first, and its runner is the gateway's);
# edge and cli share THIS one, staged into both kits from one source by
# tools/payload.sh. The only thing that varies between components is the list of
# names, which comes from migrations/component.conf.
#
# THE FOUR GUARDS, each of which has a real failure behind it:
#   1. THE OPERATOR'S HOME, NOT $HOME. The documented install is
#      `curl … | sudo sh`, where $HOME is /root or /var/root — a tree no
#      per-user install ever wrote to. A sweep aimed there finds nothing,
#      reports success and leaves every shadowing copy in place. Resolved by
#      lib_paths.sh's operator_home.
#   2. PROVABLY OURS, BY READING AND NEVER EXECUTING. The directory being swept
#      is writable by the very user whose files are in question; running one of
#      them to ask what it is would hand uid 0 to anyone who can drop a file
#      there. The evidence is the Go build stamp, read with grep.
#   3. EXACT NAMES, NEVER A GLOB, and the shared `burrowee` dispatcher last.
#   4. NOTHING IS REMOVED WHILE A UNIT STILL NAMES THE DIRECTORY. On macOS the
#      KeepAlive.PathState the installers write keys off the binary's
#      existence, so unlinking it does not stale a future restart — it stops
#      the running daemon.
# Undecidable cases fail toward KEEP.
#
# Every variable is defaulted with ${X:-…} so a caller that already resolved one
# keeps its answer. Nothing here runs at source time except these assignments
# and the component.conf load below.

# THE COMPONENT'S OWN FACTS come from migrations/component.conf, beside this
# file in the kit and owned by the component's repo. Loaded only when the
# caller has not already supplied $STALE_USER_BINS, so install.sh (which knows
# its own $BINS) and run.sh (which sourced the conf itself) both stay in
# charge of their own answer.
#
# A missing conf is NOT defaulted to a guessed list. An empty $STALE_USER_BINS
# sweeps nothing and says so at the call sites; a guessed one would delete by a
# name this component may not own.
if [ -z "${STALE_USER_BINS:-}" ]; then
    _lsub_here="${LIB_STALE_USER_BINS_DIR:-$(dirname "$0")}"
    if [ -f "$_lsub_here/component.conf" ]; then
        # shellcheck source=/dev/null
        . "$_lsub_here/component.conf"
    fi
fi
STALE_USER_BINS="${STALE_USER_BINS:-}"

# lib_paths.sh holds home_of_user / operator_home / root_home — one definition
# each, shared with run.sh and with the installers. Sourced only when the
# caller has not already loaded it (install.sh sources both, in order).
if ! command -v operator_home >/dev/null 2>&1; then
    _lsub_paths="${LIB_STALE_USER_BINS_DIR:-$(dirname "$0")}/lib_paths.sh"
    if [ -f "$_lsub_paths" ]; then
        # shellcheck source=lib_paths.sh
        . "$_lsub_paths"
    fi
fi

# The per-user directory a pre-0.2.0 install wrote to. Not a seam anyone should
# set: it is the historical default, and it is what makes the copies shadow
# $BIN_DIR on a normal PATH.
STALE_USER_BIN_SUBDIR="${STALE_USER_BIN_SUBDIR:-.local/bin}"

BIN_DIR="${BIN_DIR:-${PREFIX:-/usr/local}/bin}"
LAUNCHD_DIR="${LAUNCHD_DIR:-${BURROWEE_LAUNCHD_DIR:-/Library/LaunchDaemons}}"
SYSTEMD_DIR="${SYSTEMD_DIR:-${BURROWEE_SYSTEMD_DIR:-/etc/systemd/system}}"

# ---------------------------------------------------------------------------
# unit_naming_dir <dir> <operator-home> — the first service unit file on this
# host that still names <dir>, or empty + non-zero when none does.
#
# Guard 4. It scans the unit FILES rather than asking the supervisor, and
# treats a file on disk as "possibly loaded". That is deliberately the
# conservative direction: the two outcomes are "skip a cleanup" and "stop a
# running daemon", and only one of them is recoverable by running again. The
# system dirs cover ANOTHER component's units too (a co-installed gateway or
# relay still pointing at the per-user tree), which is the case no single
# component's own re-render can speak for.
# ---------------------------------------------------------------------------
unit_naming_dir() {
    for _und_d in "$LAUNCHD_DIR" "$SYSTEMD_DIR" \
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

# ---------------------------------------------------------------------------
# is_burrowee_binary <file> — whether <file> is one of OURS, decided by reading
# it and never by running it (guard 2).
#
# Every burrowee binary is a Go binary built from a github.com/burrowee-git/*
# module, and the toolchain stamps that module path into the build-info blob of
# the executable (the same bytes `go version -m` reads back). It survives
# -trimpath and -ldflags "-s -w", so a release build carries it exactly as a
# local one does.
#
# The claim this supports is narrow and that is the point: combined with an
# EXACT name from $STALE_USER_BINS (never a glob) and a regular-file test, a
# file that also carries our module path is ours or vendors us. An operator's
# own script that happens to share the name does not carry it, and is left
# alone.
# ---------------------------------------------------------------------------
is_burrowee_binary() {
    LC_ALL=C grep -qF 'github.com/burrowee-git/' "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# stale_bin_verdict <path> — the WHOLE ownership decision, in one place, as one
# word: absent | symlink | irregular | foreign | ours.
#
# Both callers below switch on it — the remover, to pick which note it prints,
# and the probe, to decide whether there is anything pending at all. Written as
# one function rather than as two similar chains because a probe that answered
# a slightly different question than the removal it authorises is how a rung
# gets selected and then finds nothing to do.
# ---------------------------------------------------------------------------
stale_bin_verdict() {
    if [ -h "$1" ]; then echo symlink; return 0; fi
    [ -e "$1" ] || { echo absent; return 0; }
    [ -f "$1" ] || { echo irregular; return 0; }
    if is_burrowee_binary "$1"; then echo ours; else echo foreign; fi
}

# ---------------------------------------------------------------------------
# stale_dir_has_other_burrowee_bin <dir> — whether any burrowee-* binary of
# OURS remains in <dir> after this component's own names have been swept.
#
# THIS IS THE DISPATCHER RULE. The bare `burrowee` dispatcher is shared by every
# co-installed component: it is the one name in $STALE_USER_BINS that is not
# this component's to remove unilaterally. It goes only when nothing else of
# ours is left in that directory to need it.
#
# The glob is a DETECTION over what is left, never a removal target: nothing is
# ever deleted by pattern here, only by exact name out of $STALE_USER_BINS. And
# it asks is_burrowee_binary about each candidate for the same reason the
# removal does — an operator's own `burrowee-notes` script must not be evidence
# that a burrowee component is installed, or it would pin the shadowing
# dispatcher in place forever.
# ---------------------------------------------------------------------------
stale_dir_has_other_burrowee_bin() {
    for _sdo_f in "$1"/burrowee-*; do
        [ -f "$_sdo_f" ] || continue
        if is_burrowee_binary "$_sdo_f"; then return 0; fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# remove_one_stale_bin <path> — remove ONE stale per-user copy, and only when
# it is provably ours. Absent is success, not a warning: this runs on every
# install, and a host that never had a per-user layout must say nothing at all.
# ---------------------------------------------------------------------------
remove_one_stale_bin() {
    _ros_p="$1"
    case "$(stale_bin_verdict "$_ros_p")" in
    absent) return 0 ;;
    symlink)
        echo "note: $_ros_p is a symlink, not a binary this installer placed — left in place." >&2
        return 0
        ;;
    irregular)
        echo "note: $_ros_p is not a regular file — left in place." >&2
        return 0
        ;;
    foreign)
        echo "note: $_ros_p carries no burrowee build stamp — it is not ours, left in place." >&2
        return 0
        ;;
    esac
    if rm -f "$_ros_p"; then
        echo "removed stale per-user binary: $_ros_p"
    else
        echo "note: could not remove $_ros_p — it shadows $BIN_DIR on PATH; remove it by hand." >&2
    fi
}

# ---------------------------------------------------------------------------
# stale_user_bin_dir <operator-home> — the directory to sweep, or empty when
# there is none to consider. Empty covers three cases the callers treat
# identically: no operator home resolved, no per-user bin directory on this
# host, and — the guard that is written rather than argued — a per-user
# directory that IS $BIN_DIR, where sweeping would delete the install this run
# just made.
#
# THAT THIRD CASE IS THE CLI'S NORMAL STATE, not a corner. The cli installs to
# ${PREFIX:-$HOME/.local}/bin by design, so on an ordinary cli host the
# directory to sweep and the install destination are the same directory and
# this returns empty — the cli's rung is a no-op there, correctly. It has
# something to do only on a cli whose $BIN_DIR is somewhere else (an explicit
# PREFIX, e.g. a root-owned /usr/local), where the per-user copies really are
# stale and really do shadow it on PATH.
# ---------------------------------------------------------------------------
stale_user_bin_dir() {
    _subd_home="${1:-}"
    [ -n "$_subd_home" ] || return 0
    _subd_dir="$_subd_home/$STALE_USER_BIN_SUBDIR"
    [ -d "$_subd_dir" ] || return 0
    [ "$_subd_dir" != "$BIN_DIR" ] || return 0
    echo "$_subd_dir"
}

# ---------------------------------------------------------------------------
# stale_user_bins_pending — whether a sweep right now would remove at least one
# file. The rung's --applies probe, and deliberately the same decision the
# sweep makes: guard 4 answers "no" here too, so a host whose units still name
# the per-user directory is never selected for a rung that would then decline
# to touch anything.
#
# Silent: a probe is asked speculatively, on hosts where the answer is normally
# "no", and every note it printed would appear on all of them.
# ---------------------------------------------------------------------------
stale_user_bins_pending() {
    _sbp_home="$(operator_home 2>/dev/null)"
    _sbp_dir="$(stale_user_bin_dir "$_sbp_home")"
    [ -n "$_sbp_dir" ] || return 1
    if unit_naming_dir "$_sbp_dir" "$_sbp_home" >/dev/null 2>&1; then return 1; fi

    for _sbp_b in $STALE_USER_BINS; do
        case "$_sbp_b" in burrowee) continue ;; esac
        if [ "$(stale_bin_verdict "$_sbp_dir/$_sbp_b")" = ours ]; then return 0; fi
    done
    if ! stale_dir_has_other_burrowee_bin "$_sbp_dir" &&
        [ "$(stale_bin_verdict "$_sbp_dir/burrowee")" = ours ]; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# remove_stale_user_bins — sweep the pre-0.2.0 per-user copies of THIS
# component's binaries, by exact name, after everything else has converged.
# ---------------------------------------------------------------------------
remove_stale_user_bins() {
    if [ -z "$STALE_USER_BINS" ]; then
        echo "note: no binary list for the stale per-user sweep (migrations/component.conf" >&2
        echo "note: is missing or sets no STALE_USER_BINS) — nothing was swept." >&2
        return 0
    fi
    _rsb_home="$(operator_home)"
    _rsb_dir="$(stale_user_bin_dir "$_rsb_home")"
    [ -n "$_rsb_dir" ] || return 0

    _rsb_unit=""
    _rsb_unit="$(unit_naming_dir "$_rsb_dir" "$_rsb_home")" || _rsb_unit=""
    if [ -n "$_rsb_unit" ]; then
        echo "note: $_rsb_unit still names $_rsb_dir, so a supervisor may be running a" >&2
        echo "note: binary from there — the stale per-user copies are left in place." >&2
        echo "hint: remove them by hand once nothing points at that directory." >&2
        return 0
    fi

    for _rsb_b in $STALE_USER_BINS; do
        # The bare `burrowee` dispatcher is SHARED across co-installed
        # components — so it is handled below, after the names that are
        # unambiguously this component's, and only when nothing else of ours
        # is left there.
        case "$_rsb_b" in burrowee) continue ;; esac
        remove_one_stale_bin "$_rsb_dir/$_rsb_b"
    done
    if stale_dir_has_other_burrowee_bin "$_rsb_dir"; then
        echo "kept $_rsb_dir/burrowee (dispatcher) — another burrowee component is still installed there"
    else
        remove_one_stale_bin "$_rsb_dir/burrowee"
    fi
}

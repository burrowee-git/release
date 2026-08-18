#!/bin/sh
# _shared/migrations/stale_user_bins.sh — remove the pre-0.2.0 per-user copies
# of this component's binaries. Target version 0.2.0 (see migrations/ledger).
#
# ONE STEP IN THE LADDER. run.sh owns the version gate, the receipt and the
# ordering; this script owns only the sweep. Never invoked directly by
# install.sh or update.sh — always through run.sh, so a host that skipped
# releases runs every intermediate rung in order.
#
# WHY THIS IS A RUNG AND NOT ONLY AN INSTALLER STEP. The sweep also lives in
# each component's install.sh, and it stays there — a fresh install must not
# need the ladder to be coherent. But install.sh runs only when somebody runs
# the installer, and THE UPDATER NEVER DOES: it swaps binaries and restarts the
# daemon. So a host updated in place kept its stale per-user copies indefinitely.
#
# Observed on a production node, 2026-08-17, on the gateway. The daemon was
# pushed to v0.2.0.2026.08.17.4e43c2ed while ~/.local/bin/burrowee-gateway
# stayed on the Aug 8 build, and the doctor reported a drift row its own
# recommended fix could not clear — because the doctor probes the daemon NEXT TO
# the executable that ran it, while the unit execs $BIN_DIR. Removing the
# shadowing copy is the only thing that can. edge and cli place binaries the
# same way and shadow them the same way; the difference was only that neither
# had a ladder for the rung to sit on.
#
# THE SWEEP ITSELF IS NOT REIMPLEMENTED HERE. It lives in
# lib_stale_user_bins.sh, sourced below and sourced by install.sh out of the
# same shipped directory, because every guard in it fails silently in the
# safe-looking direction and a second copy that drifted would look exactly like
# the first right up to the deletion it got wrong.
#
# WHICH NAMES IT SWEEPS come from migrations/component.conf's
# $STALE_USER_BINS — never a glob, never a guess. run.sh exports it; the
# library loads the conf itself when invoked any other way.
#
# MODES
#   --applies   exit 0 if a sweep right now would remove something. run.sh
#               calls this ONLY when no version is recorded. It is the same
#               decision the sweep makes, including the refusal below, so this
#               rung is never selected for a host where it would then decline
#               to touch anything.
#   (no args)   perform the sweep.
#
# IT REFUSES RATHER THAN DELETING OUT FROM UNDER A RUNNING DAEMON. If any unit
# file on this host still names the per-user directory, nothing is removed and
# the rung exits 0 with a note. Exit 0 and not 1 deliberately: 1 fails the whole
# ladder, and thus the install carrying it, over a cleanup that a co-installed
# component's stale unit made impossible.
#
# IDEMPOTENT. A second run finds the files gone and says nothing at all, which
# is what makes it safe for both callers and for an operator forcing the ladder
# by hand.
set -eu

# $HOME is never dereferenced bare here: this rung is reachable from a unit that
# exports neither HOME nor COMP_HOME, and under `set -u` a bare $HOME aborts the
# probe before it can answer. An aborted probe reads to run.sh exactly like
# "this rung does not apply". The library defaults it at its one use.
#
# This rung reads no component TREE at all — it is about binaries on PATH, not
# about $COMP_HOME — so $COMP_HOME is deliberately not resolved here.
#
# $BIN_DIR is the install destination, and the library's one use of it is the
# guard that refuses to sweep a directory that IS that destination. run.sh
# exports the value it resolved; the default matches the installers'.
BIN_DIR="${BIN_DIR:-${PREFIX:-/usr/local}/bin}"

HERE="$(dirname "$0")"

say()  { echo "stale_user_bins: $*"; }
warn() { echo "stale_user_bins: $*" >&2; }

# THE LIBRARY IS NOT OPTIONAL, and a missing one is a REFUSAL rather than a
# quiet no-op. A rung that exits 0 having evaluated nothing earns a receipt and
# — once the caller records the version — is gated off forever, which is the
# exact silent-loss shape the ladder exists to prevent. run.sh already refuses
# the whole run when a script named in the ledger is not in the release; this is
# the same failure one level down, and it says so the same way.
LIB="$HERE/lib_stale_user_bins.sh"
if [ ! -f "$LIB" ]; then
    warn "$LIB is missing — THIS RELEASE IS INCOMPLETE."
    warn "the sweep is not reimplemented here: it is shared with the installer, and"
    warn "a rung that cannot load it has evaluated nothing. Refusing rather than"
    warn "exiting 0, which would earn a receipt for work that never happened."
    exit 1
fi
# LIB_STALE_USER_BINS_DIR pins where the library looks for its own siblings
# (component.conf, lib_paths.sh). Without it the library would resolve them
# from $0 — which, inside a sourced file, is THIS script's path and happens to
# be right today, and would silently become wrong the first time anything else
# sources it.
LIB_STALE_USER_BINS_DIR="$HERE"
export LIB_STALE_USER_BINS_DIR
# shellcheck source=lib_stale_user_bins.sh
. "$LIB"

if [ "${1:-}" = "--applies" ]; then
    if stale_user_bins_pending; then exit 0; fi
    exit 1
fi

if [ "${1:-}" != "" ]; then
    warn "unknown argument '$1' (expected --applies or none)"
    exit 2
fi

# WHAT IT DECIDED, ALWAYS. The library names every file it removed, every file
# it left in place and why, and the unit that made it refuse; these two lines
# bracket that so a run which found nothing is still visibly a run, and not an
# absence of output an operator has to interpret.
say "sweeping the pre-0.2.0 per-user copies that shadow $BIN_DIR on PATH"
remove_stale_user_bins
say "sweep complete — anything removed, kept or left in place is named above"

#!/bin/sh
# _shared/migrations/sweep_stale_exec_root.sh — remove the 0.2 exec root's real
# copies of this component's binaries. Target version 0.3.0 (see the
# component's migrations/ledger).
#
# 0.3 moved the exec root from /usr/local/bin to /usr/local/burrowee/bin — the
# bin/ of the one machine-owned tree beside etc/<comp> and var/<comp> (spec
# 2026-08-27-v0-3-system-root-layout §6, §8 item 4). The 0.3 installer places
# every binary in the new tree and links the OPERATOR-TYPED names back into
# /usr/local/bin where that directory is root-secure; every other name it
# placed there in 0.2 — the updater above all, which a root unit execs by real
# path and nobody types — is left behind as a stale real file. So is every
# operator-typed name on a host whose /usr/local/bin was not root-secure, where
# the installer declined to link. This rung sweeps those, by exact name, per
# item.
#
# ONE STEP IN THE LADDER. run.sh owns the version gate, the receipt and the
# ordering; this script owns only the sweep. Never invoked directly.
#
# THE COPY IS NOT HERE. The component's own v0_2_to_v0_3.sh rung (in the
# component's repo — edge and relay each carry one) copies the 0.2 config and
# data trees into the new roots and leaves the sources exactly as found. A
# same-named shared file would shadow that rung in the assembled kit, which is
# why this sweep is its own rung under its own name.
#
# THE SWEEP ITSELF IS NOT REIMPLEMENTED HERE. It lives in
# lib_stale_user_bins.sh beside this file (remove_stale_exec_root_bins, outside
# the byte-pinned region, built on the region's own predicates) and is called
# by the installer too, after it has re-rendered the units. The two calls are
# not redundant: on the first 0.3 install this rung runs BEFORE the units are
# re-rendered, and while a 0.2 unit still names /usr/local/bin/<name> the
# library correctly refuses to unlink a file a supervisor may be running — so
# the rung reports that and the installer's later call does the removal. On a
# host reached only by the updater, which never runs the installer, this rung
# is what reaches the copies once the units have moved.
#
# PER ITEM, NEVER PER SECTION. Every name re-tests its own applicability where
# it runs: a symlink (ours or anyone's) is never touched, a file with no
# burrowee build stamp is not ours, a name with no trusted twin in the new
# tree is the live install, a file some unit still names may be running.
# One name's answer never decides another's.
#
# MODES
#   --applies   exit 0 if a sweep right now would remove something. FAILS
#               OPEN: a /usr/local/bin this process cannot read is "still
#               needed" — a wrong yes costs one no-op run, a wrong no strands
#               the copies behind a receipt forever.
#   (no args)   perform the sweep.
#
# IDEMPOTENT. A second run finds the files gone and says so per name.
set -eu

# The 0.3 exec root, never derived from PREFIX: ${PREFIX:-/usr/local}/bin would
# equal $LEGACY_BIN_DIR, and the library then bails ("nothing replaced anything")
# — a rung that evaluates nothing earns a receipt and is gated off forever. The
# runner exports BIN_DIR; this default covers a direct invocation only.
BIN_DIR="${BIN_DIR:-/usr/local/burrowee/bin}"

HERE="$(dirname "$0")"

say()  { echo "sweep_stale_exec_root: $*"; }
warn() { echo "sweep_stale_exec_root: $*" >&2; }

# THE LIBRARY IS NOT OPTIONAL, and a missing one is a REFUSAL rather than a
# quiet no-op — a rung that exits 0 having evaluated nothing earns a receipt
# and is gated off forever. Same rule, same wording, as stale_user_bins.sh.
LIB="$HERE/lib_stale_user_bins.sh"
if [ ! -f "$LIB" ]; then
    warn "$LIB is missing — THIS RELEASE IS INCOMPLETE."
    warn "the sweep is not reimplemented here: it is shared with the installer, and"
    warn "a rung that cannot load it has evaluated nothing. Refusing rather than"
    warn "exiting 0, which would earn a receipt for work that never happened."
    exit 1
fi
LIB_STALE_USER_BINS_DIR="$HERE"
export LIB_STALE_USER_BINS_DIR
# shellcheck source=lib_stale_user_bins.sh
. "$LIB"

if [ "${1:-}" = "--applies" ]; then
    if stale_exec_root_bins_pending; then exit 0; fi
    exit 1
fi

if [ "${1:-}" != "" ]; then
    warn "unknown argument '$1' (expected --applies or none)"
    exit 2
fi

say "sweeping the 0.2 exec root $LEGACY_BIN_DIR of real copies replaced by $BIN_DIR"
remove_stale_exec_root_bins
say "sweep complete — anything removed, kept or left in place is named above"

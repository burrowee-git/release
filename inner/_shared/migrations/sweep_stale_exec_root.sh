#!/bin/sh
# _shared/migrations/sweep_stale_exec_root.sh — remove the 0.2 exec root's real
# copies of this component's binaries. Target version 0.3.0 (see the
# component's migrations/ledger).
#
# 0.3 moved the exec root from /usr/local/bin to /usr/local/burrowee/bin — the
# bin/ of the one machine-owned tree beside etc/<comp> and var/<comp> (spec
# 2026-08-27-v0-3-system-root-layout §6, §8 item 4; §6.1's symlinks are
# SUPERSEDED — see below). The 0.3 installer places every binary in the new
# tree and NOTHING is linked back into /usr/local/bin, so every name 0.2 put
# there is left behind as a stale real file: the updater, which a root unit
# execs by real path and nobody types, and the operator-typed names alike.
# This rung sweeps them, by exact name, per item.
#
# EARLY 0.3 DID LINK, and that is why the symlink rule below is what it is.
# The first 0.3 installers symlinked the operator-typed names back into
# /usr/local/bin wherever that directory proved root-secure. On a clean modern
# Mac /usr/local/bin does not exist, so nothing was linked and the install left
# the operator no command they could type; on an Intel Mac Homebrew owns the
# directory and the check declined for the opposite reason. Both are the
# majority case, so the step was deleted and every installer now prints how to
# reach the exec root from the operator's own login shell instead. A link found
# in /usr/local/bin today is therefore a LEFTOVER of one of those releases, not
# the install's PATH entry — which is exactly what the symlink rule below
# inverted to say.
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
# the rung reports that and the installer's later call does the removal.
#
# SO THIS RUNG NEVER FINISHES THE JOB ON A CROSSING HOST, and must not pretend
# to: on the first 0.3 install every name is unit-blocked, and the copies are
# reached by the installer's own post-render call — inner/edge/install.sh's
# sweep_stale_exec_root, the gateway's units-only reinstall, relay's equivalent.
# What this rung is for is the host that reaches 0.3 with its units ALREADY
# naming the new root, where nothing else would sweep. It exits 0 either way:
# a decline is not a failure, and halting the ladder here would strand every
# row ordered after it — including the component's own 0.2→0.3 copy rung.
#
# PER ITEM, NEVER PER SECTION. Every name re-tests its own applicability where
# it runs: a file with no burrowee build stamp is not ours, a name with no
# trusted twin in the new tree is the live install, a file some unit still
# names may be running. One name's answer never decides another's.
#
# SYMLINKS: OURS GO, EVERYONE ELSE'S STAY. This rule INVERTED when the link
# step was deleted, so the old one is worth stating to show what changed.
# Every symlink used to be spared, on the grounds that it WAS the install's
# PATH entry and deleting one deleted the operator's access. Nothing links
# there any more, so a link whose target resolves directly inside $BIN_DIR is
# a leftover of an early 0.3 release sitting in a directory PATH reaches ahead
# of the exec root, and it is removed — which takes no binary with it, since
# the target is what $BIN_DIR still holds. A link pointing anywhere else is
# the operator's and stays; one that does not resolve names nobody and stays.
# The unit guard applies to a link exactly as to a file (a macOS
# KeepAlive.PathState keys off the path's existence); the twin guard does not.
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


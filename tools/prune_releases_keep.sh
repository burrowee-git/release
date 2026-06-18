#!/bin/sh
# prune_releases_keep.sh — pure stamp-selection helper for the relay private-dir prune.
#
# Usage: keep_latest <N> <stamp1> [stamp2 …]
#   Prints the stamp names that should be DELETED (all but the newest N by sort -V).
#   Input stamps are individual arguments; N must be ≥ 1.
#   Designed for unit testing — no ssh, no side effects.
#
# For the release prune workflow, caller lists remote stamps via ssh, passes them
# here, then ssh rm -rf's the printed names.
set -eu

keep_latest() {
    _n="$1"; shift
    [ "$_n" -ge 1 ] || { echo "keep_latest: N must be >= 1" >&2; return 1; }
    _count=$#
    if [ "$_count" -le "$_n" ]; then
        return 0   # nothing to delete
    fi
    # sort -V (version sort) orders stamps correctly
    printf '%s\n' "$@" | sort -V | head -n "$(( _count - _n ))"
}

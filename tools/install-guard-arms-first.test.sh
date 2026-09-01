#!/bin/sh
# tools/install-guard-arms-first.test.sh — the guard must be armed BEFORE the
# first write, not before the restart.
#
# WHY THE ORDER IS THE WHOLE TEST. There are two places an install stops the
# gateway, and only one of them is the restart. inner/_shared/migrations/
# adopt_user_tree.sh boots the daemon out to copy state at rest, and it runs
# from migrate_from_legacy — seventeen lines before load_units. On a gateway
# the operator's session is tunnelled through that daemon, so that migration
# severs the session too. A guard armed after the migration cannot see it.
set -eu

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
FILE="$HERE/inner/gateway/install.sh"
fails=0
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }

line_of() { grep -n "^$1\$" "$FILE" | head -1 | cut -d: -f1; }

L_ARM="$(line_of 'guard_arm')"
L_SNAP="$(line_of 'snapshot_take')"
L_PLACE="$(line_of 'place_all_bins')"
L_MIGRATE="$(line_of 'migrate_from_legacy')"

[ -n "$L_ARM" ]     || fail "install.sh never calls guard_arm"
[ -n "$L_SNAP" ]    || fail "install.sh never calls snapshot_take"
[ -n "$L_PLACE" ]   || fail "install.sh never calls place_all_bins"
[ -n "$L_MIGRATE" ] || fail "install.sh never calls migrate_from_legacy"

if [ -n "$L_SNAP" ] && [ -n "$L_PLACE" ] && [ "$L_SNAP" -gt "$L_PLACE" ]; then
    fail "snapshot_take (line $L_SNAP) runs AFTER place_all_bins (line $L_PLACE) — the outgoing binaries are already gone"
fi
if [ -n "$L_ARM" ] && [ -n "$L_MIGRATE" ] && [ "$L_ARM" -gt "$L_MIGRATE" ]; then
    fail "guard_arm (line $L_ARM) runs AFTER migrate_from_legacy (line $L_MIGRATE) — the migration's own stop is unguarded"
fi

# load_units must no longer be part of the foreground flow: the guard restarts.
if grep -n '^load_units$' "$FILE" >/dev/null 2>&1; then
    fail "install.sh still calls load_units in the foreground — the restart belongs to the guard"
fi

# record_installed_version MUST run before txn_phase handoff. The anchor is
# what the NEXT run's migration gate reads (record_installed_version's own
# header), so a host severed at the restart — the guard, not this script,
# owns everything from handoff on — must never be left with new binaries,
# migrated state, and a stale anchor still naming the old release. Deferred
# from Task 7 for the same reason `txn_phase handoff` itself was: the token
# this test anchors to did not exist until this task wrote it.
#
# The LAST call in the file, not the first: BURROWEE_UNITS_ONLY and update
# mode also call record_installed_version, earlier in the file and on paths
# that exit long before ever reaching handoff — the one this test cares about
# is the fresh-install flow's own, which is necessarily the last one written.
L_HANDOFF="$(line_of 'txn_phase handoff')"
L_RECORD="$(grep -n '^ *record_installed_version ' "$FILE" | tail -1 | cut -d: -f1)"

[ -n "$L_HANDOFF" ] || fail "install.sh never reaches txn_phase handoff"
[ -n "$L_RECORD" ]  || fail "install.sh never calls record_installed_version"
if [ -n "$L_RECORD" ] && [ -n "$L_HANDOFF" ] && [ "$L_RECORD" -gt "$L_HANDOFF" ]; then
    fail "record_installed_version (line $L_RECORD) runs AFTER txn_phase handoff (line $L_HANDOFF) — a host severed at the restart would keep new binaries and migrated state under a stale version anchor"
fi

if [ "$fails" -ne 0 ]; then
    printf '%s: %d check(s) failed\n' "$0" "$fails" >&2
    exit 1
fi
printf 'ok: the guard is armed before the first write\n'

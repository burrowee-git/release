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

if [ "$fails" -ne 0 ]; then
    printf '%s: %d check(s) failed\n' "$0" "$fails" >&2
    exit 1
fi
printf 'ok: the guard is armed before the first write\n'

#!/bin/sh
# tools/install-guard-arms-first.test.sh — the guard must be armed BEFORE the
# first write, not before the restart.
#
# WHY THE ORDER IS THE WHOLE TEST. There are two places an install stops the
# gateway, and only one of them is the restart. Gateway's own migration runner
# (migrations/run.sh, from the gateway repo — NOT the shared ladder, which
# gateway does not use) boots the daemon out to copy state at rest, and it runs
# from migrate_from_legacy, a long way before the restart. On a gateway the
# operator's session is tunnelled through that daemon, so that migration severs
# the session too. A guard armed after the migration cannot see it.
#
# "BEFORE load_units" is how that used to be spelled, and it is no longer true
# of this file in either half: load_units is not where the restart happens any
# more (the guard restarts), and the check further down asserts load_units is
# not called in the foreground AT ALL. Naming it as the later of the two events
# would have described an ordering between the migration and a call this file
# forbids. The ordering that survives — and the one asserted below — is
# guard_arm before migrate_from_legacy.
#
# TWO FLOWS ARE CHECKED, NOT ONE. BURROWEE_UNITS_ONLY —
# `burrowee gateway service install` and `doctor --fix` — carries the same two
# sever points and now arms the same guard, so the same ordering has to hold
# inside its mode block. It cannot be checked with the column-0 anchors the
# fresh flow uses (everything in a mode block is indented), so the block is
# extracted by line range first and the same questions are asked of it.
set -eu

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
FILE="$HERE/inner/gateway/install.sh"
fails=0
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }

# line_of <literal> — the first line that is exactly <literal> at COLUMN 0.
#
# The column matters and is not incidental: three of the four names below also
# appear indented inside the BURROWEE_UNITS_ONLY mode block, which runs long
# before the fresh-install flow this file is about. A whitespace-tolerant
# anchor would read migrate_from_legacy's units-only call site and conclude the
# guard is armed after the migration, on a file where it is armed before it.
line_of() { grep -n "^$1\$" "$FILE" | head -1 | cut -d: -f1; }

# line_of_indented <literal> — the same, but tolerating leading whitespace.
# Used ONLY for `txn_phase handoff`, which now sits inside the
# `if [ "$GUARD_ARMED" != 0 ]` block that honours BURROWEE_NO_RESTART (there is
# no handoff when no guard was armed; `!= 0` rather than `= 1` because
# GUARD_ARMED also carries `unproven` — see its declaration in install.sh). It
# appears exactly once in the file, so the tolerance cannot pick up a second,
# earlier call site the way it would for the four names above.
line_of_indented() { grep -n "^[[:space:]]*$1\$" "$FILE" | head -1 | cut -d: -f1; }

# line_of_indented_last <literal> — the LAST whitespace-tolerant match. Used
# for the fresh flow's `txn_phase handoff`, which is no longer the only one.
line_of_indented_last() { grep -n "^[[:space:]]*$1\$" "$FILE" | tail -1 | cut -d: -f1; }

# ---------------------------------------------------------------------------
# The BURROWEE_UNITS_ONLY mode block, by line range.
#
# Everything inside a mode block is indented, so the column-0 anchors above
# cannot separate it from the fresh flow — and a whitespace-tolerant grep over
# the whole file cannot either, because it would match whichever flow comes
# first. The block is bounded instead: its own `if` line, and the next line
# that is exactly `fi` at column 0. Both ends are unambiguous — install.sh has
# one such `if` per mode, and a mode block's closing `fi` is the only
# unindented one inside its range.
# ---------------------------------------------------------------------------
UO_START="$(grep -n '^if \[ -n "\${BURROWEE_UNITS_ONLY:-}" \]; then$' "$FILE" | head -1 | cut -d: -f1)"
if [ -z "$UO_START" ]; then
    fail "install.sh has no BURROWEE_UNITS_ONLY mode block — this whole half is checking nothing"
    UO_START=0; UO_END=0
else
    UO_END="$(awk -v s="$UO_START" 'NR > s && $0 == "fi" { print NR; exit }' "$FILE")"
    [ -n "$UO_END" ] || { fail "the BURROWEE_UNITS_ONLY block is never closed by a column-0 'fi'"; UO_END=0; }
fi

# uo_line_of <literal> — the first line INSIDE the units-only block that is
# <literal> with any leading whitespace.
uo_line_of() {
    grep -n "^[[:space:]]*$1\$" "$FILE" \
        | awk -F: -v a="$UO_START" -v b="$UO_END" '$1 > a && $1 < b { print $1; exit }'
}

# uo_line_of_prefix <literal-prefix> — same, for a call that carries arguments.
uo_line_of_prefix() {
    grep -n "^[[:space:]]*$1" "$FILE" \
        | awk -F: -v a="$UO_START" -v b="$UO_END" '$1 > a && $1 < b { print $1; exit }'
}

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
# mode also call record_installed_version, earlier in the file — the one this
# part of the test cares about is the fresh-install flow's own, which is
# necessarily the last one written.
#
# AND THE LAST HANDOFF, for the same reason and it is not the reason it was
# written for. `txn_phase handoff` used to appear exactly once in the file, so
# `head -1` and `tail -1` were the same line; units-only now writes one too,
# several hundred lines earlier. Left at `head -1` this check would compare the
# fresh flow's record against the UNITS-ONLY handoff and report the fresh flow
# broken — a false red that says nothing about either flow. The units-only pair
# is checked as a pair below, inside its own block.
L_HANDOFF="$(line_of_indented_last 'txn_phase handoff')"

L_RECORD="$(grep -n '^ *record_installed_version ' "$FILE" | tail -1 | cut -d: -f1)"

[ -n "$L_HANDOFF" ] || fail "install.sh never reaches txn_phase handoff"
[ -n "$L_RECORD" ]  || fail "install.sh never calls record_installed_version"
if [ -n "$L_RECORD" ] && [ -n "$L_HANDOFF" ] && [ "$L_RECORD" -gt "$L_HANDOFF" ]; then
    fail "record_installed_version (line $L_RECORD) runs AFTER txn_phase handoff (line $L_HANDOFF) — a host severed at the restart would keep new binaries and migrated state under a stale version anchor"
fi

# ---------------------------------------------------------------------------
# The same three claims, inside the BURROWEE_UNITS_ONLY block.
#
# That mode is `burrowee gateway service install` and `doctor --fix`. It has
# the SAME two sever points as the fresh flow — the migration's own stop and
# the restart — and until it armed a guard it had neither protected. The
# ordering is what makes the guard worth arming, so it is asserted here rather
# than assumed to have been copied correctly.
# ---------------------------------------------------------------------------
UO_ARM="$(uo_line_of 'guard_arm')"
UO_SNAP="$(uo_line_of 'snapshot_take')"
UO_TXN="$(uo_line_of 'txn_begin')"
UO_MIGRATE="$(uo_line_of 'migrate_from_legacy')"
UO_RENDER="$(uo_line_of 'render_units')"
UO_HANDOFF="$(uo_line_of 'txn_phase handoff')"
UO_RECORD="$(uo_line_of_prefix 'record_installed_version ')"

[ -n "$UO_ARM" ]     || fail "the units-only block never calls guard_arm — service install and doctor --fix restart the gateway unguarded"
[ -n "$UO_SNAP" ]    || fail "the units-only block never calls snapshot_take — the guard would have nothing to roll back to"
[ -n "$UO_TXN" ]     || fail "the units-only block never calls txn_begin"
[ -n "$UO_MIGRATE" ] || fail "the units-only block never calls migrate_from_legacy"
[ -n "$UO_RENDER" ]  || fail "the units-only block never calls render_units"
[ -n "$UO_HANDOFF" ] || fail "the units-only block never reaches txn_phase handoff — the restart is not the guard's"
[ -n "$UO_RECORD" ]  || fail "the units-only block never calls record_installed_version"

# The snapshot must be taken before the guard is armed, and both before the
# first write. remove_legacy_user_units is that first write; the migration is
# the first STOP.
if [ -n "$UO_TXN" ] && [ -n "$UO_SNAP" ] && [ "$UO_TXN" -gt "$UO_SNAP" ]; then
    fail "units-only: txn_begin (line $UO_TXN) runs after snapshot_take (line $UO_SNAP) — there is no transaction to snapshot into"
fi
if [ -n "$UO_ARM" ] && [ -n "$UO_SNAP" ] && [ "$UO_SNAP" -gt "$UO_ARM" ]; then
    fail "units-only: snapshot_take (line $UO_SNAP) runs after guard_arm (line $UO_ARM) — the guard is armed with no working point to roll back to"
fi
if [ -n "$UO_ARM" ] && [ -n "$UO_MIGRATE" ] && [ "$UO_ARM" -gt "$UO_MIGRATE" ]; then
    fail "units-only: guard_arm (line $UO_ARM) runs AFTER migrate_from_legacy (line $UO_MIGRATE) — the migration's own stop is unguarded, and that stop is what severs a tunnelled operator's session on this path"
fi
if [ -n "$UO_ARM" ] && [ -n "$UO_RENDER" ] && [ "$UO_ARM" -gt "$UO_RENDER" ]; then
    fail "units-only: guard_arm (line $UO_ARM) runs AFTER render_units (line $UO_RENDER) — units were written before the snapshot could record the ones they replace"
fi
# The anchor, before the point of no return. Same claim as the fresh flow's,
# and the same reason: record_installed_version is what the NEXT run's
# migration gate reads.
if [ -n "$UO_RECORD" ] && [ -n "$UO_HANDOFF" ] && [ "$UO_RECORD" -gt "$UO_HANDOFF" ]; then
    fail "units-only: record_installed_version (line $UO_RECORD) runs AFTER txn_phase handoff (line $UO_HANDOFF) — a session severed at the restart leaves migrated state under a stale version anchor"
fi

# The restart belongs to the guard on this path too: no load_units, and no
# sweep_stale_user_bins in the foreground (the sweep deletes per-user binaries
# and may only run after a VERIFIED restart, which is inside the guard).
if [ "$UO_START" -gt 0 ] && [ -n "$(uo_line_of 'load_units')" ]; then
    fail "the units-only block still calls load_units — that restarts the daemon in this shell's foreground, on the connection tunnelled through it"
fi
if [ "$UO_START" -gt 0 ] && [ -n "$(uo_line_of 'sweep_stale_user_bins')" ]; then
    fail "the units-only block still calls sweep_stale_user_bins in the foreground — it must run only after the guard has verified the restart, or it deletes a binary a still-running per-user process names"
fi

if [ "$fails" -ne 0 ]; then
    printf '%s: %d check(s) failed\n' "$0" "$fails" >&2
    exit 1
fi
printf 'ok: the guard is armed before the first write, on both guarded flows\n'

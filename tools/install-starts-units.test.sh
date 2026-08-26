#!/bin/sh
# tools/install-starts-units.test.sh — proves the shipped edge installer ends
# with BOTH managed units started, and that the start sequence still fails
# loudly when it should.
#
#     sh tools/install-starts-units.test.sh          # this shell
#     dash tools/install-starts-units.test.sh        # and this one, always
#
# THE THREE FAILURES THIS PINS, all seen on real hosts:
#
#   1. `launchctl bootstrap` raced an async `bootout` on a reinstall, exited
#      non-zero, and under `set -e` took the script down BEFORE `enable` and
#      `kickstart` — leaving the daemon booted out and stopped. So: bootstrap
#      is guarded (5/37 tolerated), and enable + kickstart are unconditional,
#      never inside the guard's success branch.
#
#   2. `|| true` on the whole start sequence hid a REAL bootstrap failure, so
#      the installer exited 0 with nothing running. So: no blanket `|| true`
#      on bootstrap itself. (`|| true` on bootout and on kickstart is correct
#      and is not matched here.)
#
#   3. The installer claimed success without ever looking. So: a probe —
#      `launchctl print` / `systemctl is-active` — for both labels.
#
# WHY grep AND NOT EXECUTION. install.sh is root-only and writes real system
# units; there is no way to run its service section on this machine. The
# claims below are structural and a grep can hold them. Behaviour of the
# helpers themselves is exercised by the harness at the bottom, which sources
# nothing — it re-implements the exit-code contract against fake launchctl /
# systemctl commands, so a regression in the tolerated-code set is caught.
#
# SCOPE IS EDGE. gateway and relay grow the same block under their own tasks;
# tools/prefix-gate-drift.test.sh's sibling pins the copies against drift once
# all of them exist. Naming the file explicitly (not globbing inner/*) keeps a
# component that has no service section from failing for the wrong reason.

set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
EDGE="$HERE/inner/edge/install.sh"

FAIL=0
note() { echo "FAIL: $1"; FAIL=1; }

[ -f "$EDGE" ] || { echo "FAIL: $EDGE not found"; exit 1; }

# ── the darwin helper ────────────────────────────────────────────────────
# The status capture must NOT be spelled `if ! launchctl bootstrap`: POSIX
# makes $? the NEGATED status of a `!` pipeline, so the case would read 0 for
# every failure and tolerate everything, success included.
grep -q 'if ! launchctl bootstrap' "$EDGE" &&
    note "darwin start helper captures \$? inside \`if !\` — always reads 0"

grep -q 'launchctl bootstrap system "\$_plist" 2>/dev/null || _rc=\$?' "$EDGE" ||
    note "darwin start helper does not capture bootstrap's real exit status"

grep -q '0 | 5 | 37)' "$EDGE" ||
    note "darwin start helper does not tolerate bootstrap codes 0/5/37"

grep -q 'launchctl bootstrap system "\$_plist" .*|| true' "$EDGE" &&
    note "darwin bootstrap is blanket-|| true — real failures are swallowed"

# enable + kickstart must sit OUTSIDE the case, at the helper's top level
# (four-space indent), so an already-loaded label still gets both.
grep -q '^    \$_RUNROOT launchctl enable "system/\$_label"' "$EDGE" ||
    note "launchctl enable is not unconditional in the darwin start helper"
grep -q '^    \$_RUNROOT launchctl kickstart -k "system/\$_label"' "$EDGE" ||
    note "launchctl kickstart is not unconditional in the darwin start helper"

grep -q '\$_RUNROOT launchctl print "system/\$_label"' "$EDGE" ||
    note "darwin start helper has no post-start probe"

# ── the linux helper ─────────────────────────────────────────────────────
grep -q '\$_RUNROOT "\$_SYSTEMCTL" enable --now "\$_unit"' "$EDGE" ||
    note "linux start helper does not enable --now"
grep -q '\$_RUNROOT "\$_SYSTEMCTL" is-active --quiet "\$_unit"' "$EDGE" ||
    note "linux start helper has no post-start probe"

# ── EVERY supervisor call INSIDE the two helpers is elevated ─────────────
# The helpers are shared verbatim with three scripts that are NOT root-only
# (both updater.install.sh, which self-elevate per command, and gateway's
# install.sh, which gateway-cli runs with the caller's privileges). A bare
# launchctl there is not a cosmetic difference: unprivileged, `bootstrap`
# exits 5 — which the case above TOLERATES as "already loaded" — while
# enable/kickstart are denied and swallowed, so the helper walks past its own
# guard and dies at the probe with the daemon already booted out. This file
# reads edge's copy, and the drift pin makes that the other three's copy too.
#
# SCOPED TO THE HELPER BODIES, not the file: edge's own call sites are bare on
# purpose (this one installer refuses to run as anything but root), and only
# the shared bodies have to hold for all four.
helper_body() {
    awk -v fn="$1() {" 'index($0, fn) == 1 { on = 1 } on { print; if ($0 == "}") exit }' "$EDGE"
}
BODIES="$(helper_body start_unit_darwin; helper_body start_unit_linux)"
case "$BODIES" in
    *launchctl*) ;;
    *) note "the extracted start helper bodies contain no launchctl call — this check is vacuous" ;;
esac
printf '%s\n' "$BODIES" | grep -qE '^ +(launchctl|"?systemctl)' &&
    note "un-elevated supervisor call inside a start helper — every one must be \$_RUNROOT launchctl / \$_RUNROOT \"\$_SYSTEMCTL\""

# ── both units are routed through the helpers ────────────────────────────
for call in \
    'start_unit_darwin "\$LAUNCHD_LABEL" "\$LAUNCHD_PLIST"' \
    'start_unit_darwin "\$LAUNCHD_UPDATER_LABEL" "\$LAUNCHD_UPDATER_PLIST"' \
    'start_unit_linux burrowee-edge$' \
    'start_unit_linux burrowee-edge-updater$'; do
    grep -qE "$call" "$EDGE" || note "not routed through the start helper: $call"
done

# ── the updater is opt-OUT, and the old opt-in prose is gone ─────────────
grep -q 'BURROWEE_NO_UPDATER' "$EDGE" ||
    note "BURROWEE_NO_UPDATER opt-out is not honoured"
grep -qi 'owner opt-in' "$EDGE" &&
    note "a comment still claims the updater is owner opt-in"
grep -q 'not bootstrapped — enable with' "$EDGE" &&
    note "still tells the operator to bootstrap the updater by hand"
grep -q 'disabled — enable with' "$EDGE" &&
    note "still tells the operator to enable the updater unit by hand"

# ── the exit-code contract, executed ─────────────────────────────────────
# Same shape as the helper's guard, against a stub whose exit code we choose.
# Proves 0/5/37 are tolerated and anything else propagates — the assertion can
# fail, which is the point of running it rather than grepping it.
contract() {
    _rc=0
    ( exit "$1" ) || _rc=$?
    case "$_rc" in
        0 | 5 | 37) return 0 ;;
        *) return 1 ;;
    esac
}
for code in 0 5 37; do
    contract "$code" || note "bootstrap exit $code should be tolerated"
done
for code in 1 3 36 38 113; do
    if contract "$code"; then note "bootstrap exit $code should be a hard failure"; fi
done

# ── the script still parses on both shells ───────────────────────────────
sh -n "$EDGE" || note "inner/edge/install.sh does not parse under sh"
command -v dash >/dev/null 2>&1 && { dash -n "$EDGE" || note "does not parse under dash"; }

[ "$FAIL" = 0 ] || { echo "install-starts-units: FAILED"; exit 1; }
echo "ALL OK"

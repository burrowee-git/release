#!/bin/sh
# _shared/migrations/adopt_updater_unit_test.sh — the suite for
# adopt_updater_unit.sh: the rung that converges a legacy PER-USER updater
# agent onto the SYSTEM unit.
#
#     sh inner/_shared/migrations/adopt_updater_unit_test.sh          # this shell
#     dash inner/_shared/migrations/adopt_updater_unit_test.sh        # and this one, always
#
# NEVER TOUCHES A REAL SUPERVISOR, A REAL /usr/local, OR ANY PATH OUTSIDE ITS
# OWN TEMP DIR. LAUNCHCTL and SYSTEMCTL are both pointed at one fake
# "supervisor" script that only logs its argv and answers from flag files this
# suite controls; SUDO is a stub that logs then execs for real, so the rung's
# own file writes land inside $TMP and nowhere else. LAUNCHD_PLIST_DIR and
# SYSTEMD_UNIT_DIR are likewise fixture paths, never /Library/LaunchDaemons or
# /etc/systemd/system.
#
# BOTH PLATFORM BRANCHES ARE EXERCISED IN EVERY RUN, regardless of the host
# this suite happens to run on: `uname` is stubbed via a fake binary placed
# first on PATH (stub_uname), the same technique
# inner/edge/install_test/render_test.go uses (stubUname) to pin `uname -s`
# without needing two machines.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"

FAILED=0
CASES=0
fail() { FAILED=$((FAILED + 1)); echo "FAIL: $*" >&2; }
assert_eq() {
    CASES=$((CASES + 1))
    if [ "$1" != "$2" ]; then fail "$3: want [$2] got [$1]"; fi
}
assert_contains() {
    CASES=$((CASES + 1))
    case "$1" in
    *"$2"*) ;;
    *) fail "$3: output does not contain [$2]
--- output ---
$1
--- end ---" ;;
    esac
}
assert_present() {
    CASES=$((CASES + 1))
    if [ ! -e "$1" ]; then fail "$2 ($1 is gone)"; fi
}
assert_line_before() {
    # assert_line_before <log> <needle-earlier> <needle-later> <label>
    CASES=$((CASES + 1))
    _lb_a="$(grep -n -m1 -F -- "$2" "$1" | cut -d: -f1)"
    _lb_b="$(grep -n -m1 -F -- "$3" "$1" | cut -d: -f1)"
    if [ -z "$_lb_a" ]; then fail "$4: [$2] never appears in the log"; return; fi
    if [ -z "$_lb_b" ]; then fail "$4: [$3] never appears in the log"; return; fi
    if [ "$_lb_a" -ge "$_lb_b" ]; then
        fail "$4: [$2] (line $_lb_a) did not precede [$3] (line $_lb_b)"
    fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

# ---------------------------------------------------------------------------
# stub_uname <dir> <Darwin|Linux> — a fake `uname` first on PATH, so both of
# adopt_updater_unit.sh's platform branches run regardless of the real host.
# ---------------------------------------------------------------------------
# The real `uname` binary's absolute path, resolved ONCE before any stub goes
# on PATH, so the stub's fallback (for the arg shapes adopt_updater_unit.sh
# never actually uses) execs the real one directly rather than searching PATH
# again — which would find itself first and recurse.
REAL_UNAME="$(command -v uname)"

stub_uname() {
    mkdir -p "$1"
    {
        echo '#!/bin/sh'
        echo "if [ \"\$1\" = -s ]; then echo $2; exit 0; fi"
        echo "exec $REAL_UNAME \"\$@\""
    } > "$1/uname"
    chmod 0755 "$1/uname"
}

# make_supervisor_stub <dir> — a stand-in for BOTH launchctl and systemctl.
# Logs every invocation (to $SUP_LOG, read from its own environment). THREE
# legacy surfaces, matching adopt_updater_unit.sh's own three (gui-domain,
# system-domain, and systemd --user), each independently controllable:
#   * gui/<uid>/… (Darwin gui-domain, e.g. org.burrowee.edge-updater):
#     print/etc succeed iff $SUP_FLAGS/legacy-gui-present exists; a bootout
#     touches $SUP_FLAGS/reached-bootout-gui and, when
#     $SUP_FLAGS/slow-bootout-gui exists, sleeps 2s first.
#   * system/org.burrowee.… (Darwin system-domain legacy, e.g.
#     org.burrowee.edge.updater — NOT the new com.burrowee.* target, which
#     falls through to the optimistic catch-all below): print/etc succeed iff
#     $SUP_FLAGS/legacy-sys-present exists; a bootout touches
#     $SUP_FLAGS/reached-bootout-sys and sleeps when
#     $SUP_FLAGS/slow-bootout-sys exists.
#   * --user … (Linux, the systemd --user instance): succeeds iff
#     $SUP_FLAGS/legacy-present exists; a disable --now touches
#     $SUP_FLAGS/reached-bootout-user and sleeps when
#     $SUP_FLAGS/slow-bootout-user exists.
#   * everything else (the NEW system unit's own bootstrap/enable/kickstart/
#     print/daemon-reload/enable --now — Darwin's "system/com.burrowee.…" and
#     Linux's non---user calls) always succeeds — the system side of every
#     case below is optimistic.
make_supervisor_stub() {
    mkdir -p "$1"
    cat > "$1/supervisor" <<'STUB'
#!/bin/sh
printf 'supervisor %s\n' "$*" >> "$SUP_LOG"
case "$*" in
*'gui/'*)
    case "$*" in
    *bootout*)
        : > "$SUP_FLAGS/reached-bootout-gui"
        [ -f "$SUP_FLAGS/slow-bootout-gui" ] && sleep 2
        exit 0
        ;;
    esac
    [ -f "$SUP_FLAGS/legacy-gui-present" ] && exit 0
    exit 1
    ;;
*'system/org.burrowee.'*)
    case "$*" in
    *bootout*)
        : > "$SUP_FLAGS/reached-bootout-sys"
        [ -f "$SUP_FLAGS/slow-bootout-sys" ] && sleep 2
        exit 0
        ;;
    esac
    [ -f "$SUP_FLAGS/legacy-sys-present" ] && exit 0
    exit 1
    ;;
*'--user'*)
    case "$*" in
    *'disable --now'*)
        : > "$SUP_FLAGS/reached-bootout-user"
        [ -f "$SUP_FLAGS/slow-bootout-user" ] && sleep 2
        exit 0
        ;;
    esac
    [ -f "$SUP_FLAGS/legacy-present" ] && exit 0
    exit 1
    ;;
esac
exit 0
STUB
    chmod 0755 "$1/supervisor"
}

# make_sudo_stub <dir> — logs then execs for real, so the rung's own mkdir/tee
# calls actually write into the fixture paths this suite points it at, and any
# supervisor call made THROUGH sudo still reaches the stub above (and so still
# gets logged by it too — harmless duplication, never a second code path).
make_sudo_stub() {
    mkdir -p "$1"
    cat > "$1/sudo" <<'STUB'
#!/bin/sh
printf 'sudo %s\n' "$*" >> "$SUP_LOG"
exec "$@"
STUB
    chmod 0755 "$1/sudo"
}

# run_rung <home> <comp> [args…] — one direct invocation of the rung, env
# resolved exactly as run.sh's run_migration exports it (see run.sh), plus
# this suite's fixture seams. Never through run.sh itself except in the
# receipt case below, which needs run.sh's own machinery.
run_rung() {
    _rr_home="$1"; _rr_comp="$2"; shift 2
    SUP_LOG="$_rr_home/log" \
    SUP_FLAGS="$_rr_home/flags" \
    COMP="$_rr_comp" \
    BIN_DIR="$_rr_home/bin" \
    SUDO="$_rr_home/stubs/sudo" \
    LAUNCHCTL="$_rr_home/stubs/supervisor" \
    SYSTEMCTL="$_rr_home/stubs/supervisor" \
    LAUNCHD_PLIST_DIR="$_rr_home/Library/LaunchDaemons" \
    SYSTEMD_UNIT_DIR="$_rr_home/etc/systemd/system" \
    ROOT_HOME="$_rr_home/root-home" \
    PATH="$_rr_home/platform:$PATH" \
        sh "$HERE/adopt_updater_unit.sh" "$@"
}

# seed_home <home> <comp> — a fixture tree: an executable "updater" binary
# (the rung's pre-flight requires it) plus the log/flags directories.
seed_home() {
    _sh_home="$1"; _sh_comp="$2"
    mkdir -p "$_sh_home/bin" "$_sh_home/flags" "$_sh_home/stubs"
    printf '#!/bin/sh\ntrue\n' > "$_sh_home/bin/burrowee-$_sh_comp-updater"
    chmod 0755 "$_sh_home/bin/burrowee-$_sh_comp-updater"
    : > "$_sh_home/log"
    make_supervisor_stub "$_sh_home/stubs"
    make_sudo_stub "$_sh_home/stubs"
}

# ---------------------------------------------------------------------------
# Case (a): ORDER. The system unit is written — and loaded — BEFORE any
# bootout of the legacy one. Run on both platforms.
# ---------------------------------------------------------------------------
run_order_case() {
    _oc_goos="$1"
    h="$TMP/order-$_oc_goos"
    seed_home "$h" edge
    stub_uname "$h/platform" "$_oc_goos"
    : > "$h/flags/legacy-present"
    : > "$h/flags/legacy-gui-present"
    : > "$h/flags/legacy-sys-present"

    OUT="$(run_rung "$h" edge 2>&1)"; RC=$?
    assert_eq "$RC" "0" "order ($_oc_goos): a converging run must exit 0"

    if [ "$_oc_goos" = Darwin ]; then
        assert_present "$h/Library/LaunchDaemons/com.burrowee.edge.updater.plist" \
            "order ($_oc_goos): the system LaunchDaemon must be written"
        # BOTH legacy domains — the gui-domain per-user agent AND the
        # system-domain pre-rename unit — must be booted out only after the
        # new unit is written and loaded. Two independent needles, so a
        # regression that reorders only one domain still reddens.
        assert_line_before "$h/log" "tee $h/Library/LaunchDaemons/com.burrowee.edge.updater.plist" \
            "supervisor bootout gui/" "order ($_oc_goos): write must precede gui-domain legacy bootout"
        assert_line_before "$h/log" "bootstrap system" "bootout gui/" \
            "order ($_oc_goos): load must precede gui-domain legacy bootout"
        assert_line_before "$h/log" "tee $h/Library/LaunchDaemons/com.burrowee.edge.updater.plist" \
            "bootout system/org.burrowee.edge.updater" "order ($_oc_goos): write must precede system-domain legacy bootout"
        assert_line_before "$h/log" "bootstrap system" "bootout system/org.burrowee.edge.updater" \
            "order ($_oc_goos): load must precede system-domain legacy bootout"
    else
        assert_present "$h/etc/systemd/system/burrowee-edge-updater.service" \
            "order ($_oc_goos): the system unit must be written"
        assert_line_before "$h/log" "tee $h/etc/systemd/system/burrowee-edge-updater.service" \
            "--user disable --now" "order ($_oc_goos): write must precede legacy bootout"
        assert_line_before "$h/log" "enable --now burrowee-edge-updater.service" \
            "--user disable --now" "order ($_oc_goos): load must precede legacy bootout"
    fi
    assert_contains "$OUT" "converged burrowee-edge-updater to the system unit" \
        "order ($_oc_goos): the rung must say it converged"
}
run_order_case Darwin
run_order_case Linux

# ---------------------------------------------------------------------------
# Case (a3): ONE PER LEGACY LABEL/DOMAIN COMBINATION (Darwin has two; a rung
# that checks only one domain silently matches nothing on a host running only
# the other — exactly the failure mode a bare "it exited 0" cannot catch,
# since a wrongly-skipped run ALSO exits 0.
# ---------------------------------------------------------------------------

# (a3-gui) ONLY the gui-domain per-user agent (org.burrowee.edge-updater) is
# present — no system-domain survivor. Must still converge.
h_guionly="$TMP/gui-only"
seed_home "$h_guionly" edge
stub_uname "$h_guionly/platform" Darwin
: > "$h_guionly/flags/legacy-gui-present"
OUT_GUIONLY="$(run_rung "$h_guionly" edge 2>&1)"; RC_GUIONLY=$?
assert_eq "$RC_GUIONLY" "0" "gui-only: a converging run must exit 0"
assert_contains "$OUT_GUIONLY" "converged burrowee-edge-updater to the system unit" \
    "gui-only: must recognise the gui-domain agent alone and converge"
assert_present "$h_guionly/Library/LaunchDaemons/com.burrowee.edge.updater.plist" \
    "gui-only: the system unit must be written"

# (a3-sys) ONLY the system-domain pre-rename unit (org.burrowee.edge.updater)
# is present — no gui-domain agent. THIS is the case the coordinator's review
# caught missing entirely: before this fix, legacy_unit_present() never
# queried the system domain at all, so a host in exactly this state read as
# "nothing to converge" and was left stranded on the label the rung exists to
# retire.
h_sysonly="$TMP/sys-only"
seed_home "$h_sysonly" edge
stub_uname "$h_sysonly/platform" Darwin
: > "$h_sysonly/flags/legacy-sys-present"
OUT_SYSONLY="$(run_rung "$h_sysonly" edge 2>&1)"; RC_SYSONLY=$?
assert_eq "$RC_SYSONLY" "0" "sys-only: a converging run must exit 0"
assert_contains "$OUT_SYSONLY" "converged burrowee-edge-updater to the system unit" \
    "sys-only: must recognise the system-domain legacy unit alone and converge"
assert_present "$h_sysonly/Library/LaunchDaemons/com.burrowee.edge.updater.plist" \
    "sys-only: the system unit must be written"
assert_contains "$(cat "$h_sysonly/log")" "bootout system/org.burrowee.edge.updater" \
    "sys-only: the system-domain legacy label must actually be booted out"

# (a3-linux) the --user domain, same shape as before (single legacy surface).
h_useronly="$TMP/user-only"
seed_home "$h_useronly" edge
stub_uname "$h_useronly/platform" Linux
: > "$h_useronly/flags/legacy-present"
OUT_USERONLY="$(run_rung "$h_useronly" edge 2>&1)"; RC_USERONLY=$?
assert_eq "$RC_USERONLY" "0" "user-only: a converging run must exit 0"
assert_contains "$OUT_USERONLY" "converged burrowee-edge-updater to the system unit" \
    "user-only: must recognise the systemd --user legacy unit and converge"

# (a3-phantom) ONLY the phantom label an earlier draft invented
# (com.burrowee.<comp>-updater, hyphenated with the com prefix) reads as
# "present" — a label that appears nowhere in edge, gateway, relay or core.
# The FIXED rung must not be fooled by it: with neither real legacy domain
# present, this must still read as nothing to converge. (There is no flag for
# this phantom label in the stub at all — its absence from make_supervisor_stub
# IS the proof the rung no longer queries it; this case documents that
# omission is deliberate rather than accidental, by confirming the negative
# outcome any residual reference to it would break.)
h_phantom="$TMP/phantom-only"
seed_home "$h_phantom" edge
stub_uname "$h_phantom/platform" Darwin
# deliberately NOT setting legacy-gui-present or legacy-sys-present
OUT_PHANTOM="$(run_rung "$h_phantom" edge 2>&1)"; RC_PHANTOM=$?
assert_eq "$RC_PHANTOM" "0" "phantom-only: must still exit 0"
assert_contains "$OUT_PHANTOM" "nothing to converge" \
    "phantom-only: with no real legacy label present, must find nothing to converge"
if [ -e "$h_phantom/Library/LaunchDaemons/com.burrowee.edge.updater.plist" ]; then
    fail "phantom-only: must NOT write a system unit when no real legacy label is present"
else CASES=$((CASES + 1)); fi

# (a3-phantom-static) THE DYNAMIC CASE ABOVE CANNOT, ON ITS OWN, TELL "the
# phantom label was queried and found absent" apart from "the phantom label
# was never queried at all" — both produce an identical "nothing to
# converge". Verified by hand: temporarily reintroducing a
# LEGACY_PHANTOM_LABEL="com.burrowee.$COMP-updater" query into the rung
# alongside the two real ones did NOT redden the case above — the stub's
# gui-domain branch answers for ANY gui-domain query off the SAME
# legacy-gui-present flag, phantom or real, so a query the rung should not be
# making at all was invisible to it there. A static check closes that gap:
# the phantom string must never appear in the rung's own source, full stop.
if grep -qF 'com.burrowee.$COMP-updater' "$HERE/adopt_updater_unit.sh"; then
    fail "phantom-static: the phantom label pattern com.burrowee.\$COMP-updater must not appear in adopt_updater_unit.sh"
else
    CASES=$((CASES + 1))
fi

# ---------------------------------------------------------------------------
# Case (a2): a host with NO legacy agent (never opted in) must NOT be silently
# enrolled — the real run's own re-check, independent of run.sh's --applies.
# ---------------------------------------------------------------------------
h_noop="$TMP/no-legacy"
seed_home "$h_noop" edge
stub_uname "$h_noop/platform" Linux
# deliberately no "$h_noop/flags/legacy-present"
OUT_NOOP="$(run_rung "$h_noop" edge 2>&1)"; RC_NOOP=$?
assert_eq "$RC_NOOP" "0" "no-legacy: must still exit 0"
assert_contains "$OUT_NOOP" "nothing to converge" "no-legacy: must say why it did nothing"
if [ -e "$h_noop/etc/systemd/system/burrowee-edge-updater.service" ]; then
    fail "no-legacy: must NOT write a system unit for a host that never opted in"
else CASES=$((CASES + 1)); fi

# ---------------------------------------------------------------------------
# Case (b): RECEIPT PRESENT — a re-run through run.sh is a clean no-op. This
# is run.sh's own contract, not the rung's, so it is exercised through a
# minimal kit rather than by calling the rung directly.
# ---------------------------------------------------------------------------
h_kit="$TMP/kit"
mkdir -p "$h_kit/migrations"
cp "$HERE/run.sh" "$h_kit/migrations/run.sh"
cp "$HERE/lib_paths.sh" "$h_kit/migrations/lib_paths.sh"
cp "$HERE/adopt_updater_unit.sh" "$h_kit/migrations/adopt_updater_unit.sh"
chmod 0755 "$h_kit/migrations/run.sh" "$h_kit/migrations/adopt_updater_unit.sh"
{
    echo "COMP=edge"
    echo "COMP_HOME_SCHEME=user"
    echo "VERSION_FILE=installed-version"
} > "$h_kit/migrations/component.conf"
printf '0.2.0 adopt_updater_unit.sh\n' > "$h_kit/migrations/ledger"

h_recpt="$TMP/receipt-home"
seed_home "$h_recpt" edge
stub_uname "$h_recpt/platform" Linux
: > "$h_recpt/flags/legacy-present"
mkdir -p "$h_recpt/comp-home"

run_via_run_sh() {
    SUP_LOG="$h_recpt/log" \
    SUP_FLAGS="$h_recpt/flags" \
    COMP_HOME="$h_recpt/comp-home" \
    BIN_DIR="$h_recpt/bin" \
    SUDO="$h_recpt/stubs/sudo" \
    LAUNCHCTL="$h_recpt/stubs/supervisor" \
    SYSTEMCTL="$h_recpt/stubs/supervisor" \
    LAUNCHD_PLIST_DIR="$h_recpt/Library/LaunchDaemons" \
    SYSTEMD_UNIT_DIR="$h_recpt/etc/systemd/system" \
    ROOT_HOME="$h_recpt/root-home" \
    PATH="$h_recpt/platform:$PATH" \
        sh "$h_kit/migrations/run.sh" --installed-version 0.1.0 2>&1
}

run_via_run_sh >/dev/null; RUN1_RC=$?
assert_eq "$RUN1_RC" "2" "receipt: the first run must migrate (exit 2 — migrations ran)"
assert_present "$h_recpt/comp-home/migration-receipts/adopt_updater_unit.sh@0.2.0.done" \
    "receipt: run.sh must have written the item's receipt"
LOG_LINES_AFTER_RUN1="$(wc -l < "$h_recpt/log" | tr -d ' ')"

RUN2_OUT="$(run_via_run_sh)"; RUN2_RC=$?
assert_eq "$RUN2_RC" "0" "receipt: a re-run with the receipt present must exit 0 (nothing applied)"
assert_contains "$RUN2_OUT" "skipped: its receipt records it completed here" \
    "receipt: the skip must be named"
LOG_LINES_AFTER_RUN2="$(wc -l < "$h_recpt/log" | tr -d ' ')"
assert_eq "$LOG_LINES_AFTER_RUN2" "$LOG_LINES_AFTER_RUN1" \
    "receipt: a receipted re-run must touch NO supervisor — no new log lines"

# ---------------------------------------------------------------------------
# Case (c): KILLED AFTER THE INSTALL, BEFORE THE BOOTOUT — a real SIGKILL,
# mid-sleep inside the legacy bootout call, must still converge on the next
# run rather than leaving neither unit.
# ---------------------------------------------------------------------------
h_kill="$TMP/kill"
seed_home "$h_kill" edge
stub_uname "$h_kill/platform" Linux
: > "$h_kill/flags/legacy-present"
: > "$h_kill/flags/slow-bootout-user"

# Backgrounded as ONE plain simple command, deliberately NOT wrapped in a
# `( … ) &` subshell: POSIX only guarantees $! names the process that was
# actually backgrounded, and `sh script.sh` interprets the script IN that same
# process (no further fork) — so $KILL_PID below is the PID of the rung's own
# execution, not a subshell wrapper that may or may not have been optimised
# away. Killing anything OTHER than that PID would let the "killed" run
# finish in the background and make this case prove nothing.
SUP_LOG="$h_kill/log" \
SUP_FLAGS="$h_kill/flags" \
COMP="edge" \
BIN_DIR="$h_kill/bin" \
SUDO="$h_kill/stubs/sudo" \
LAUNCHCTL="$h_kill/stubs/supervisor" \
SYSTEMCTL="$h_kill/stubs/supervisor" \
LAUNCHD_PLIST_DIR="$h_kill/Library/LaunchDaemons" \
SYSTEMD_UNIT_DIR="$h_kill/etc/systemd/system" \
ROOT_HOME="$h_kill/root-home" \
PATH="$h_kill/platform:$PATH" \
    sh "$HERE/adopt_updater_unit.sh" >"$h_kill/run1.out" 2>&1 &
KILL_PID=$!

# Poll for the marker the stub touches the instant it enters the (slow) legacy
# bootout call — proof steps 1 and 2 (write + load) already completed.
_kw=0
while [ ! -f "$h_kill/flags/reached-bootout-user" ] && [ "$_kw" -lt 50 ]; do
    sleep 0.1
    _kw=$((_kw + 1))
done
if [ ! -f "$h_kill/flags/reached-bootout-user" ]; then
    fail "kill: the run never reached the legacy bootout call — cannot test the kill window"
else
    CASES=$((CASES + 1))
fi

# The kill itself: SIGKILL, not a signal the script could catch or clean up
# after — the whole point is that nothing downstream of this line ran.
kill -KILL "$KILL_PID" 2>/dev/null
wait "$KILL_PID" 2>/dev/null

assert_present "$h_kill/etc/systemd/system/burrowee-edge-updater.service" \
    "kill: the system unit written before the kill must have survived it"

rm -f "$h_kill/flags/slow-bootout-user"
LOG_LINES_BEFORE_RERUN="$(wc -l < "$h_kill/log" | tr -d ' ')"

RERUN_OUT="$(
    SUP_LOG="$h_kill/log" \
    SUP_FLAGS="$h_kill/flags" \
    COMP="edge" \
    BIN_DIR="$h_kill/bin" \
    SUDO="$h_kill/stubs/sudo" \
    LAUNCHCTL="$h_kill/stubs/supervisor" \
    SYSTEMCTL="$h_kill/stubs/supervisor" \
    LAUNCHD_PLIST_DIR="$h_kill/Library/LaunchDaemons" \
    SYSTEMD_UNIT_DIR="$h_kill/etc/systemd/system" \
    ROOT_HOME="$h_kill/root-home" \
    PATH="$h_kill/platform:$PATH" \
        sh "$HERE/adopt_updater_unit.sh" 2>&1
)"; RERUN_RC=$?

assert_eq "$RERUN_RC" "0" "kill: the re-run must converge cleanly (exit 0)"
assert_contains "$RERUN_OUT" "converged burrowee-edge-updater to the system unit" \
    "kill: the re-run must complete all three steps, including the bootout the kill interrupted"
assert_present "$h_kill/etc/systemd/system/burrowee-edge-updater.service" \
    "kill: the system unit must still be present after the re-run"
LOG_LINES_AFTER_RERUN="$(wc -l < "$h_kill/log" | tr -d ' ')"
if [ "$LOG_LINES_AFTER_RERUN" -le "$LOG_LINES_BEFORE_RERUN" ]; then
    fail "kill: the re-run must have made new supervisor calls (write+load+bootout again) — none were seen"
else
    CASES=$((CASES + 1))
fi
# Never a window with neither unit: the system unit file exists both
# immediately after the kill AND after the re-run — asserted above at both
# points — and at no point in between was it removed (write only ever
# overwrites, per write_system_unit's own contract; nothing here deletes it).

# ---------------------------------------------------------------------------
# Case (c2): KILLED BETWEEN THE TWO LEGACY DOMAINS — Darwin only, since it is
# the only platform with two. THIS DOES NOT FOLLOW AUTOMATICALLY FROM CASE
# (c) ABOVE and is asserted explicitly rather than assumed: case (c) proves a
# kill before bootout_legacy ever starts still converges; this proves a kill
# AFTER the gui-domain half of bootout_legacy has already completed but
# BEFORE the system-domain half does — the window that exists only because
# there are now two independent sub-steps inside step 3, not one. Same
# argument, but it has to hold for BOTH halves independently (each is its own
# idempotent no-op-when-already-gone call — see bootout_legacy's header) or a
# kill in exactly this window would leave the system-domain legacy unit
# stranded forever, since nothing else on this ladder revisits it.
# ---------------------------------------------------------------------------
h_kill2="$TMP/kill-cross-domain"
seed_home "$h_kill2" edge
stub_uname "$h_kill2/platform" Darwin
: > "$h_kill2/flags/legacy-gui-present"
: > "$h_kill2/flags/legacy-sys-present"
# The gui-domain bootout is left FAST (no slow-bootout-gui) so it completes
# before the kill window; only the system-domain half is made slow, so the
# kill lands strictly between the two.
: > "$h_kill2/flags/slow-bootout-sys"

SUP_LOG="$h_kill2/log" SUP_FLAGS="$h_kill2/flags" COMP="edge" BIN_DIR="$h_kill2/bin" SUDO="$h_kill2/stubs/sudo" LAUNCHCTL="$h_kill2/stubs/supervisor" SYSTEMCTL="$h_kill2/stubs/supervisor" LAUNCHD_PLIST_DIR="$h_kill2/Library/LaunchDaemons" SYSTEMD_UNIT_DIR="$h_kill2/etc/systemd/system" ROOT_HOME="$h_kill2/root-home" PATH="$h_kill2/platform:$PATH"     sh "$HERE/adopt_updater_unit.sh" >"$h_kill2/run1.out" 2>&1 &
KILL2_PID=$!

# Poll for the SYSTEM-domain marker specifically — proof the gui-domain
# bootout already ran (it is not slow, so it is done by the time the process
# reaches the system-domain call) and execution is now inside the second half
# of step 3.
_kw2=0
while [ ! -f "$h_kill2/flags/reached-bootout-sys" ] && [ "$_kw2" -lt 50 ]; do
    sleep 0.1
    _kw2=$((_kw2 + 1))
done
if [ ! -f "$h_kill2/flags/reached-bootout-sys" ]; then
    fail "kill (cross-domain): the run never reached the system-domain bootout — cannot test the window"
else
    CASES=$((CASES + 1))
fi
if [ ! -f "$h_kill2/flags/reached-bootout-gui" ]; then
    fail "kill (cross-domain): the gui-domain bootout must have already run before the system-domain one started"
else
    CASES=$((CASES + 1))
fi

kill -KILL "$KILL2_PID" 2>/dev/null
wait "$KILL2_PID" 2>/dev/null

rm -f "$h_kill2/flags/slow-bootout-sys"
LOG2_LINES_BEFORE_RERUN="$(wc -l < "$h_kill2/log" | tr -d ' ')"

RERUN2_OUT="$(
    SUP_LOG="$h_kill2/log"     SUP_FLAGS="$h_kill2/flags"     COMP="edge"     BIN_DIR="$h_kill2/bin"     SUDO="$h_kill2/stubs/sudo"     LAUNCHCTL="$h_kill2/stubs/supervisor"     SYSTEMCTL="$h_kill2/stubs/supervisor"     LAUNCHD_PLIST_DIR="$h_kill2/Library/LaunchDaemons"     SYSTEMD_UNIT_DIR="$h_kill2/etc/systemd/system"     ROOT_HOME="$h_kill2/root-home"     PATH="$h_kill2/platform:$PATH"         sh "$HERE/adopt_updater_unit.sh" 2>&1
)"; RERUN2_RC=$?

assert_eq "$RERUN2_RC" "0" "kill (cross-domain): the re-run must converge cleanly (exit 0)"
assert_contains "$RERUN2_OUT" "converged burrowee-edge-updater to the system unit" \
    "kill (cross-domain): the re-run must complete, including the system-domain bootout the kill interrupted"
LOG2_LINES_AFTER_RERUN="$(wc -l < "$h_kill2/log" | tr -d ' ')"
if [ "$LOG2_LINES_AFTER_RERUN" -le "$LOG2_LINES_BEFORE_RERUN" ]; then
    fail "kill (cross-domain): the re-run must have made new supervisor calls — none were seen"
else
    CASES=$((CASES + 1))
fi
# The re-run repeats BOTH bootout calls (gui-domain again, harmlessly, per its
# own no-op-when-gone contract, AND system-domain, completing what the kill
# interrupted) — proven by the "converged" line above, which this rung only
# ever prints after bootout_legacy returns having attempted both.

echo "cases: $CASES  failed: $FAILED"
if [ "$FAILED" = 0 ]; then echo "ALL OK"; else echo "TESTS FAILED"; exit 1; fi

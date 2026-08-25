#!/bin/sh
# tools/adopt_updater_unit.test.sh — the suite for
# inner/_shared/migrations/adopt_updater_unit.sh: the rung that converges a
# legacy PER-USER updater agent onto the SYSTEM unit.
#
#     sh tools/adopt_updater_unit.test.sh          # this shell
#     dash tools/adopt_updater_unit.test.sh        # and this one, always
#
# IT LIVES IN tools/, NOT BESIDE THE RUNG. Everything under
# inner/_shared/migrations/ is STAGED INTO EVERY KIT by tools/payload.sh and
# cmd/rkit/assemble.go, which glob the directory rather than list it — so a
# suite beside its subject shipped 25 KB of test harness, chmod 0755, to every
# edge, cli and relay host. Every other shell suite in this repo is
# tools/<name>.test.sh for the same reason; this one is now no different.
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

HERE="$(cd "$(dirname "$0")/../inner/_shared/migrations" && pwd)"

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
REAL_ID="$(command -v id)"

stub_uname() {
    mkdir -p "$1"
    {
        echo '#!/bin/sh'
        echo "if [ \"\$1\" = -s ]; then echo $2; exit 0; fi"
        echo "exec $REAL_UNAME \"\$@\""
    } > "$1/uname"
    chmod 0755 "$1/uname"
}

# ---------------------------------------------------------------------------
# stub_id <dir> <uid> — a fake `id` first on PATH, so `id -u` answers the same
# thing no matter who runs this suite.
#
# NOT COSMETIC. adopt_updater_unit.sh's elevate() runs the command DIRECTLY
# when `id -u` says 0 and through $SUDO otherwise, so a suite run as root
# (every CI container) would never touch the sudo stub at all: the sudo-failure
# case below would silently prove nothing, and every ordering assertion that
# reads a `sudo …` line out of the log would be asserting about the developer's
# account rather than about the rung.
# ---------------------------------------------------------------------------
stub_id() {
    mkdir -p "$1"
    {
        echo '#!/bin/sh'
        echo "if [ \"\$1\" = -u ] && [ \$# = 1 ]; then echo $2; exit 0; fi"
        echo "exec $REAL_ID \"\$@\""
    } > "$1/id"
    chmod 0755 "$1/id"
}

# make_supervisor_stub <dir> — a stand-in for BOTH launchctl and systemctl.
# Logs every invocation (to $SUP_LOG, read from its own environment). FOUR
# surfaces, matching adopt_updater_unit.sh's own — the three legacy ones
# (gui-domain, system-domain, systemd --user) and, since the coordinator's
# final review, THE NEW SYSTEM UNIT ITSELF:
#   * gui/<uid>/… (Darwin gui-domain, e.g. org.burrowee.edge-updater):
#     print/etc succeed iff $SUP_FLAGS/legacy-gui-present exists; a bootout
#     touches $SUP_FLAGS/reached-bootout-gui and, when
#     $SUP_FLAGS/slow-bootout-gui exists, sleeps 2s first.
#   * system/org.burrowee.… (Darwin system-domain legacy, e.g.
#     org.burrowee.edge.updater): print/etc succeed iff
#     $SUP_FLAGS/legacy-sys-present exists; a bootout touches
#     $SUP_FLAGS/reached-bootout-sys and sleeps when
#     $SUP_FLAGS/slow-bootout-sys exists.
#   * system/com.burrowee.… (Darwin, THE NEW UNIT — the surface an
#     optimistic catch-all used to answer for, which is why no test could see
#     enable_system_unit booting out its own job): print/enable/kickstart
#     succeed iff $SUP_FLAGS/sys-unit-loaded exists, and a successful
#     `bootstrap system …` CREATES that flag, so a converged fixture re-runs
#     as a genuinely partially-converged host. A bootout touches
#     $SUP_FLAGS/reached-bootout-self and, when
#     $SUP_FLAGS/bootout-self-kills exists, SIGKILLs $PPID — the rung's own
#     shell — because that is what launchd does to the process tree of the job
#     it boots out, and the rung runs under that job. `procinfo <pid>` names
#     SOME OTHER job by default, the new unit's own label when
#     $SUP_FLAGS/procinfo-self exists, and nothing at all (exit 1) when
#     $SUP_FLAGS/procinfo-silent does — the three answers the rung's
#     running_under_sys_label has to tell apart.
#   * --user … (Linux, the systemd --user instance). The BUS and the UNIT are
#     separate facts here, because `systemctl --user is-active` exits non-zero
#     identically for both and only one of them prints a word:
#       $SUP_FLAGS/no-user-bus  → every query prints NOTHING and exits 1
#                                 (systemd's "Failed to connect to bus").
#       otherwise               → is-active prints `active` (exit 0) when
#                                 $SUP_FLAGS/legacy-present exists and
#                                 `inactive` (exit 3) when it does not — a
#                                 reachable manager always answers, even about
#                                 a unit it has never heard of. is-enabled
#                                 prints `enabled` for legacy-present or
#                                 $SUP_FLAGS/legacy-enabled, and nothing (exit
#                                 1) otherwise.
#     A disable --now touches $SUP_FLAGS/reached-bootout-user and sleeps when
#     $SUP_FLAGS/slow-bootout-user exists.
#   * everything else (daemon-reload, `enable --now <unit>`) always succeeds.
make_supervisor_stub() {
    mkdir -p "$1"
    cat > "$1/supervisor" <<'STUB'
#!/bin/sh
printf 'supervisor %s\n' "$*" >> "$SUP_LOG"
case "$*" in
*procinfo*)
    if [ -f "$SUP_FLAGS/procinfo-silent" ]; then exit 1; fi
    if [ -f "$SUP_FLAGS/procinfo-self" ]; then
        echo 'label = com.burrowee.edge.updater'
    else
        echo 'label = com.apple.Terminal'
    fi
    exit 0
    ;;
*'bootstrap system'*)
    : > "$SUP_FLAGS/sys-unit-loaded"
    exit 0
    ;;
*'system/com.burrowee.'*)
    case "$*" in
    *bootout*)
        : > "$SUP_FLAGS/reached-bootout-self"
        if [ -f "$SUP_FLAGS/bootout-self-kills" ]; then
            kill -KILL "$PPID" 2>/dev/null
        fi
        exit 0
        ;;
    esac
    [ -f "$SUP_FLAGS/sys-unit-loaded" ] && exit 0
    exit 1
    ;;
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
    if [ -f "$SUP_FLAGS/no-user-bus" ]; then
        echo 'Failed to connect to bus: No medium found' >&2
        exit 1
    fi
    case "$*" in
    *is-active*)
        if [ -f "$SUP_FLAGS/legacy-present" ]; then echo active; exit 0; fi
        echo inactive
        exit 3
        ;;
    *is-enabled*)
        if [ -f "$SUP_FLAGS/legacy-present" ] || [ -f "$SUP_FLAGS/legacy-enabled" ]; then
            echo enabled
            exit 0
        fi
        echo 'Failed to get unit file state: No such file or directory' >&2
        exit 1
        ;;
    esac
    exit 0
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
#
# IT CAN ALSO FAIL, and until it could there was no way to express the host
# this rung exists for. The headline legacy case is a launchd GUI agent: no
# tty, no cached credential, and $SUDO is `sudo -n`, which never prompts — so
# EVERY elevated step fails there, and a stub that always exec'd made that
# state untestable. $SUP_FLAGS/sudo-fails turns it on per case.
make_sudo_stub() {
    mkdir -p "$1"
    cat > "$1/sudo" <<'STUB'
#!/bin/sh
printf 'sudo %s\n' "$*" >> "$SUP_LOG"
if [ -f "$SUP_FLAGS/sudo-fails" ]; then
    echo 'sudo: a password is required' >&2
    exit 1
fi
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
    # A NON-ROOT uid for every case: see stub_id. The per-case stub_uname call
    # writes into the same directory and does not disturb this.
    stub_id "$_sh_home/platform" 501
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

# ---------------------------------------------------------------------------
# Case (d): SUDO FAILS — the host this rung exists for.
#
# A legacy launchd GUI agent has no tty and no cached credential, and $SUDO is
# `sudo -n`, which never prompts. Every elevated step below therefore fails on
# exactly the hosts the rung is aimed at. Until the sudo stub could fail, this
# state was not expressible at all — which is why the rung shipped writing
# /Library/LaunchDaemons through a sudo that could not work, failing deep in
# step 1 with "could not create /Library/LaunchDaemons" and exiting 1.
#
# EXIT 1 IS THE OUTCOME THAT MUST NOT HAPPEN. updater.update.sh treats any
# ladder result outside {0,2,3} as fatal and returns BEFORE restart_updater, so
# the host keeps a freshly-placed updater binary and a never-restarted updater
# service — and the updater is the only automatic delivery channel, so no later
# release can reach it. 3 (DEFERRED) is non-fatal there: the binary lands, the
# service restarts, the operator is told.
# ---------------------------------------------------------------------------
run_no_root_case() {
    _nr_goos="$1"
    h="$TMP/no-root-$_nr_goos"
    seed_home "$h" edge
    stub_uname "$h/platform" "$_nr_goos"
    : > "$h/flags/legacy-present"
    : > "$h/flags/legacy-gui-present"
    : > "$h/flags/legacy-sys-present"
    : > "$h/flags/sudo-fails"

    OUT="$(run_rung "$h" edge 2>&1)"; RC=$?
    assert_eq "$RC" "3" "no-root ($_nr_goos): an unelevatable host must DEFER (exit 3), never fail (1)"
    assert_contains "$OUT" "cannot reach root" \
        "no-root ($_nr_goos): it must say root could not be reached, up front"
    assert_contains "$OUT" "DEFERRED" "no-root ($_nr_goos): the outcome must be named"
    assert_contains "$OUT" "sudo sh $HERE/adopt_updater_unit.sh" \
        "no-root ($_nr_goos): it must name the exact command an operator has to run"
    # Nothing written and nothing touched: the pre-flight runs BEFORE step 1,
    # so this is a refusal that cost the host nothing.
    if [ -e "$h/Library/LaunchDaemons/com.burrowee.edge.updater.plist" ] ||
        [ -e "$h/etc/systemd/system/burrowee-edge-updater.service" ]; then
        fail "no-root ($_nr_goos): a deferred run must not have written a system unit"
    else CASES=$((CASES + 1)); fi
    for _nr_f in reached-bootout-gui reached-bootout-sys reached-bootout-user reached-bootout-self; do
        if [ -e "$h/flags/$_nr_f" ]; then
            fail "no-root ($_nr_goos): a deferred run must not have booted anything out ($_nr_f)"
        else CASES=$((CASES + 1)); fi
    done
}
run_no_root_case Darwin
run_no_root_case Linux

# (d2) …AND THE RUNNER TURNS THAT INTO ITS OWN EXIT 3, not exit 1. The rung's
# code is only half the contract: run.sh maps a rung's exit to the code
# updater.update.sh switches on, and before this fix every non-zero rung exit
# became exit 1 there — the fatal one.
h_defer="$TMP/defer-run-sh"
seed_home "$h_defer" edge
stub_uname "$h_defer/platform" Linux
: > "$h_defer/flags/legacy-present"
: > "$h_defer/flags/sudo-fails"
mkdir -p "$h_defer/comp-home"
DEFER_OUT="$(
    SUP_LOG="$h_defer/log" \
    SUP_FLAGS="$h_defer/flags" \
    COMP_HOME="$h_defer/comp-home" \
    BIN_DIR="$h_defer/bin" \
    SUDO="$h_defer/stubs/sudo" \
    LAUNCHCTL="$h_defer/stubs/supervisor" \
    SYSTEMCTL="$h_defer/stubs/supervisor" \
    LAUNCHD_PLIST_DIR="$h_defer/Library/LaunchDaemons" \
    SYSTEMD_UNIT_DIR="$h_defer/etc/systemd/system" \
    ROOT_HOME="$h_defer/root-home" \
    PATH="$h_defer/platform:$PATH" \
        sh "$h_kit/migrations/run.sh" --installed-version 0.1.0 2>&1
)"; DEFER_RC=$?
assert_eq "$DEFER_RC" "3" "defer: run.sh must report a deferred rung as 3 (still pending), not 1 (failed)"
assert_contains "$DEFER_OUT" "DEFERRED" "defer: the runner must name the deferral"
if [ -e "$h_defer/comp-home/migration-receipts/adopt_updater_unit.sh@0.2.0.done" ]; then
    fail "defer: a deferred rung must earn NO receipt — it did not run"
else CASES=$((CASES + 1)); fi

# ---------------------------------------------------------------------------
# Case (e): A PARTIALLY CONVERGED HOST — the new system unit is loaded, a
# legacy agent is still around, and the process walking this ladder is a child
# of that new unit's own job. Reloading it there (bootout + bootstrap) kills
# the process tree mid-step-2: bootstrap never runs, the plist sits on disk
# with nothing loaded behind it, and only a reboot or a manual bootstrap
# recovers. The stub now makes that kill REAL (SIGKILL to the rung's own shell,
# which is what launchd does), so the case can be red.
#
# (e1) IDENTICAL CONTENT: there is nothing to reload, so nothing is booted out.
# ---------------------------------------------------------------------------
h_pc="$TMP/partial-converged"
seed_home "$h_pc" edge
stub_uname "$h_pc/platform" Darwin
: > "$h_pc/flags/legacy-gui-present"
OUT_PC1="$(run_rung "$h_pc" edge 2>&1)"; RC_PC1=$?
assert_eq "$RC_PC1" "0" "partial (e1): the first run must converge normally"
assert_present "$h_pc/flags/sys-unit-loaded" \
    "partial (e1): a successful bootstrap must leave the new unit loaded"
# Now it IS the partially-converged host: unit loaded, legacy still present —
# and this time a bootout of the new unit kills the caller.
: > "$h_pc/flags/bootout-self-kills"
rm -f "$h_pc/flags/reached-bootout-self"
OUT_PC2="$(run_rung "$h_pc" edge 2>&1)"; RC_PC2=$?
assert_eq "$RC_PC2" "0" "partial (e1): the re-run must survive and converge, not be killed by its own bootout"
assert_contains "$OUT_PC2" "converged burrowee-edge-updater to the system unit" \
    "partial (e1): the re-run must reach the end"
assert_contains "$OUT_PC2" "already loaded from identical content" \
    "partial (e1): it must say why it did not reload"
if [ -e "$h_pc/flags/reached-bootout-self" ]; then
    fail "partial (e1): the rung booted out its OWN job — the process running it"
else CASES=$((CASES + 1)); fi

# (e2) THE POSITIVE CONTROL, so (e1) is not passing because the stub's kill is
# inert: same partially-converged host, but the plist on disk no longer matches
# what this run renders AND procinfo names some other job — the one shape where
# a real reload is both needed and safe. The bootout happens, and the stub's
# SIGKILL lands, proving the kill is real and that (e1) survived on the guard
# rather than on a stub that never fires.
h_pc2="$TMP/partial-converged-changed"
seed_home "$h_pc2" edge
stub_uname "$h_pc2/platform" Darwin
: > "$h_pc2/flags/legacy-gui-present"
run_rung "$h_pc2" edge >/dev/null 2>&1
printf '\n<!-- drifted -->\n' >> "$h_pc2/Library/LaunchDaemons/com.burrowee.edge.updater.plist"
: > "$h_pc2/flags/bootout-self-kills"
rm -f "$h_pc2/flags/reached-bootout-self"
OUT_PC3="$(run_rung "$h_pc2" edge 2>&1)"; RC_PC3=$?
assert_present "$h_pc2/flags/reached-bootout-self" \
    "partial (e2): a changed plist under ANOTHER job must still be reloaded for real"
if [ "$RC_PC3" = 0 ]; then
    fail "partial (e2): the stub's self-kill never fired — (e1) proves nothing while this passes"
else CASES=$((CASES + 1)); fi

# (e3) CHANGED CONTENT, BUT IT IS OUR OWN JOB: the reload is still the caller's
# to do — updater.update.sh's restart_updater runs last for exactly this
# reason — so the rung leaves the plist on disk and does not bootout.
h_pc3="$TMP/partial-converged-ours"
seed_home "$h_pc3" edge
stub_uname "$h_pc3/platform" Darwin
: > "$h_pc3/flags/legacy-gui-present"
run_rung "$h_pc3" edge >/dev/null 2>&1
printf '\n<!-- drifted -->\n' >> "$h_pc3/Library/LaunchDaemons/com.burrowee.edge.updater.plist"
: > "$h_pc3/flags/bootout-self-kills"
: > "$h_pc3/flags/procinfo-self"
rm -f "$h_pc3/flags/reached-bootout-self"
OUT_PC4="$(run_rung "$h_pc3" edge 2>&1)"; RC_PC4=$?
assert_eq "$RC_PC4" "0" "partial (e3): a changed plist under OUR OWN job must not be reloaded here"
assert_contains "$OUT_PC4" "leaving the reload to the caller" \
    "partial (e3): it must say who reloads instead"
if [ -e "$h_pc3/flags/reached-bootout-self" ]; then
    fail "partial (e3): the rung booted out the job it is running under"
else CASES=$((CASES + 1)); fi

# ---------------------------------------------------------------------------
# Case (f): LINUX — "cannot connect to the bus" is not "the unit is gone".
#
# `systemctl --user is-active` exits non-zero identically for both, and the
# rung used to read that as a confirmed absence — the opposite of its own
# documented contract. The stub now separates the two facts: an unreachable
# manager prints NOTHING, a reachable one always prints a state word.
#
# (f1) UNREACHABLE BUS: --applies must still answer "still needed".
# ---------------------------------------------------------------------------
h_bus="$TMP/no-user-bus"
seed_home "$h_bus" edge
stub_uname "$h_bus/platform" Linux
: > "$h_bus/flags/no-user-bus"
run_rung "$h_bus" edge --applies >/dev/null 2>&1; RC_BUS_APPLIES=$?
assert_eq "$RC_BUS_APPLIES" "0" \
    "linux (f1): with no user bus, --applies must answer 'still needed', not 'gone'"

# (f2) …and the REAL run must neither converge blind nor pretend it converged:
# on Linux the legacy unit name and the target unit name are the same string,
# so a blind write would overwrite the installer's own unit on every host. It
# says the case is out of scope and writes nothing.
OUT_BUS="$(run_rung "$h_bus" edge 2>&1)"; RC_BUS=$?
assert_eq "$RC_BUS" "0" "linux (f2): an unobservable host must not fail the ladder"
assert_contains "$OUT_BUS" "OUT OF SCOPE" \
    "linux (f2): the unhandled per-user Linux case must be named in the output, not silently skipped"
assert_contains "$OUT_BUS" "cannot reach a systemd USER manager" \
    "linux (f2): it must say WHY it cannot answer"
if [ -e "$h_bus/etc/systemd/system/burrowee-edge-updater.service" ]; then
    fail "linux (f2): it must not write a system unit off a guess"
else CASES=$((CASES + 1)); fi

# (f3) A REACHABLE MANAGER THAT SAYS `inactive` IS A REAL ABSENCE — the answer
# that must NOT be conflated with (f1). Same exit code from is-active, opposite
# meaning, and only the state word tells them apart.
h_inactive="$TMP/user-bus-inactive"
seed_home "$h_inactive" edge
stub_uname "$h_inactive/platform" Linux
# no legacy-present, no no-user-bus: the manager answers "inactive"/nothing-enabled.
run_rung "$h_inactive" edge --applies >/dev/null 2>&1; RC_INACT_APPLIES=$?
assert_eq "$RC_INACT_APPLIES" "1" \
    "linux (f3): a manager that answers 'inactive' is a confirmed absence — --applies must decline"
OUT_INACT="$(run_rung "$h_inactive" edge 2>&1)"; RC_INACT=$?
assert_eq "$RC_INACT" "0" "linux (f3): a confirmed absence is a clean no-op"
assert_contains "$OUT_INACT" "nothing to converge" "linux (f3): it must say so"

# (f4) INSTALLED BUT STOPPED still needs converging: is-active says `inactive`,
# is-enabled says `enabled`, and the unit is exactly the thing this rung
# retires. A predicate that stopped at is-active would strand it.
h_enabled="$TMP/user-bus-enabled-only"
seed_home "$h_enabled" edge
stub_uname "$h_enabled/platform" Linux
: > "$h_enabled/flags/legacy-enabled"
OUT_EN="$(run_rung "$h_enabled" edge 2>&1)"; RC_EN=$?
assert_eq "$RC_EN" "0" "linux (f4): an enabled-but-stopped legacy unit must converge"
assert_contains "$OUT_EN" "converged burrowee-edge-updater to the system unit" \
    "linux (f4): a stopped legacy unit is still a legacy unit"

echo "cases: $CASES  failed: $FAILED"
if [ "$FAILED" = 0 ]; then echo "ALL OK"; else echo "TESTS FAILED"; exit 1; fi

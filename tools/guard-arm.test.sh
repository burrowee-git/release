#!/bin/sh
# tools/guard-arm.test.sh — guard_arm resolves guard.sh BESIDE THIS INSTALLER
# ("$(dirname "$0")/guard.sh"), never at $GW_HOME, and hands it to whichever
# supervisor the host actually has.
#
#     sh tools/guard-arm.test.sh
#     dash tools/guard-arm.test.sh
#
# WHY THE RESOLUTION IS THE WHOLE TEST. A prior draft of guard_arm resolved
# "$GW_HOME/guard.sh" — a path keep_installer_copy has not populated yet on a
# fresh install (it runs AFTER guard_arm, see install-guard-arms-first.test.sh)
# and never populates at all on the payload's own first run. That would refuse
# every fresh install outright. The regression test below plants a DECOY
# guard.sh at the old, wrong location and proves guard_arm never reads it.
#
# BOTH PLATFORM SHAPES. guard_arm's Darwin branch writes a transient
# LaunchDaemon and drives launchctl; its Linux branch drives systemd-run
# directly, with no unit file at all. Assertion bodies are written once and
# parameterised per platform (see the loop at the bottom), the same shape
# guard-snapshot.test.sh and guard-rollback.test.sh already established.
set -eu

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
INSTALL_SRC="$HERE/inner/gateway/install.sh"
GUARD_SRC="$HERE/inner/gateway/guard.sh"
fails=0
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }

# stage_payload <root> <with_guard: yes|no> — a copy of install.sh (and,
# unless <with_guard> is "no", guard.sh beside it) under <root>/payload, the
# shape a real unpacked release zip takes. Echoes the staged install.sh path.
stage_payload() {
    _sp_root="$1"; _sp_with_guard="$2"
    _sp_dir="$_sp_root/payload"
    mkdir -p "$_sp_dir"
    cp "$INSTALL_SRC" "$_sp_dir/install.sh"
    if [ "$_sp_with_guard" = yes ]; then
        cp "$GUARD_SRC" "$_sp_dir/guard.sh"
    fi
    printf '%s\n' "$_sp_dir/install.sh"
}

# setup_root <root> — the sandboxed system-tree fixture every case below
# shares: $BIN_DIR (which is also where guard_arm places the guard), the unit
# dir, and both system roots.
setup_root() {
    mkdir -p "$1/bin" "$1/units" "$1/etc/gateway" "$1/var/gateway"
}

# make_sudo_stub <dir> — a pass-through `sudo`, same shape as
# guard-snapshot.test.sh's: install.sh's run_root always tries to elevate, and
# this suite's fixtures are tmpdirs the test process already owns.
make_sudo_stub() {
    mkdir -p "$1"
    cat > "$1/sudo" <<'STUB'
#!/bin/sh
[ "$1" = "-n" ] && shift
exec "$@"
STUB
    chmod 755 "$1/sudo"
}

# make_uname_stub <dir> <platform> — pins `uname -s`, same shape as
# guard-snapshot.test.sh's: guard_arm branches on it directly.
make_uname_stub() {
    mkdir -p "$1"
    _mu_plat="$2"
    cat > "$1/uname" <<STUB
#!/bin/sh
if [ "\$1" = "-s" ]; then echo $_mu_plat; else /usr/bin/uname "\$@"; fi
STUB
    chmod 755 "$1/uname"
}

# make_supervisor_stub <dir> <platform> <root> [start: yes|no] — the ONE
# supervisor command guard_arm actually drives for <platform>: launchctl on
# Darwin, systemd-run on Linux. Records argv and exits 0. Real launchctl and
# systemd-run talk to the HOST's own init system — exactly the shared-machine
# side effect every stub in this suite exists to prevent.
#
# IT SIMULATES THE JOB STARTING, and that is not decoration. guard_arm now
# polls for the guard's own first two artefacts ($TXN_DIR/guard.pid, a
# "guard armed" line in guard.log) before it lets the install proceed, because
# `launchctl bootstrap` and `systemd-run` exiting 0 mean the job was LOADED,
# not that it RAN — a guard that dies on exec used to produce a green install
# that restarted nothing. A stub that only records argv is exactly that dead
# guard, so it writes the artefacts a real start would: the guard's own
# contract, faked at the seam this suite owns.
#
# <start> = "no" makes it the DEAD guard on purpose, for
# t_guard_arm_refuses_when_the_guard_never_starts below.
make_supervisor_stub() {
    _ms_dir="$1"; _ms_plat="$2"; _ms_root="$3"; _ms_start="${4:-yes}"
    case "$_ms_plat" in
    Darwin)
        cat > "$_ms_dir/launchctl" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$_ms_root/launchctl.calls"
if [ "$_ms_start" = yes ] && [ "\$1" = bootstrap ]; then
    # \$3 is the plist; the transaction dir is its second ProgramArguments
    # string. Read it back out rather than re-deriving it, so a plist that
    # names the wrong directory fails this poll instead of passing it.
    _txn="\$(sed -n 's|.*<string>\\(.*/install/[^<]*\\)</string>.*|\\1|p' "\$3" | head -1)"
    [ -n "\$_txn" ] && { printf '9999\n' > "\$_txn/guard.pid"; printf '00:00:00 guard armed for \$_txn\n' >> "\$_txn/guard.log"; }
fi
exit 0
STUB
        chmod 755 "$_ms_dir/launchctl"
        ;;
    Linux)
        cat > "$_ms_dir/systemd-run" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$_ms_root/systemd-run.calls"
if [ "$_ms_start" = yes ]; then
    # The transaction dir is systemd-run's last argument.
    for _a in "\$@"; do _txn="\$_a"; done
    case "\$_txn" in
      */install/*) printf '9999\n' > "\$_txn/guard.pid"; printf '00:00:00 guard armed for \$_txn\n' >> "\$_txn/guard.log" ;;
    esac
fi
exit 0
STUB
        chmod 755 "$_ms_dir/systemd-run"
        ;;
    esac
}

# run_guard_arm <root> <platform> <installer> <snippet> [<home>] — source the
# staged installer (BURROWEE_SOURCE_ONLY short-circuits its own mode dispatch)
# with $0 pointed at <installer> — the trick that makes
# "$(dirname "$0")/guard.sh" resolve to where THIS harness staged guard.sh,
# the same way a real invocation's $0 is the installer's own path — then run
# <snippet> against its functions. $HOME (not GW_HOME directly: install.sh
# assigns GW_HOME="$HOME/.burrowee/gateway" unconditionally, so HOME is the
# only seam that reaches it) defaults to <root>/home.
run_guard_arm() {
    _rga_root="$1"; _rga_plat="$2"; _rga_installer="$3"; _rga_snippet="$4"
    _rga_home="${5:-$_rga_root/home}"
    _rga_stub="$_rga_root/.stub"
    mkdir -p "$_rga_stub" "$_rga_home"
    make_sudo_stub "$_rga_stub"
    make_uname_stub "$_rga_stub" "$_rga_plat"
    make_supervisor_stub "$_rga_stub" "$_rga_plat" "$_rga_root" "${RGA_START:-yes}"
    HOME="$_rga_home" \
    BURROWEE_SOURCE_ONLY=1 \
    PATH="$_rga_stub:$PATH" \
    BURROWEE_BIN_DIR="$_rga_root/bin" \
    BURROWEE_LAUNCHD_DIR="$_rga_root/units" \
    BURROWEE_SYSTEMD_DIR="$_rga_root/units" \
    BURROWEE_SYSTEM_CONFIG_DIR="$_rga_root/etc/gateway" \
    BURROWEE_SYSTEM_DATA_DIR="$_rga_root/var/gateway" \
    GUARD_ARM_CEILING="${RGA_ARM_CEILING:-4}" GUARD_ARM_INTERVAL=1 \
    sh -c '. "$0"; eval "$1"' "$_rga_installer" "$_rga_snippet"
}

# guard_arm must find guard.sh beside the installer, place it AS ROOT onto the
# root-secure surface ($BIN_DIR — the same one ensure_root_exec_surface places
# into and verify_root_exec_surface walks), and hand THAT copy to the right
# supervisor for the platform. Run once per platform shape (see the loop at the
# bottom) — do not copy-paste this body per platform.
#
# THE DESTINATION IS $BIN_DIR AND NOT A libexec TREE, and that is the fix, not
# an incidental refactor. The first cut copied guard.sh into a freshly created
# /usr/local/libexec/burrowee and ran it from there, and NEITHER end was
# checked: the source could be the operator-writable $GW_HOME copy on a
# default-mode re-run of the kept installer, and the destination was never
# walked by path_is_root_secure — so on an Intel macOS host where Homebrew
# chowns /usr/local it was a user-writable path a root LaunchDaemon execs at
# every arm, re-armed at every boot. $BIN_DIR already has placement,
# verification and uninstall; a second root-exec surface had none of the three.

t_guard_arm_finds_guard_beside_installer() {
    _plat="$1"
    _root="$(mktemp -d)"
    setup_root "$_root"
    _installer="$(stage_payload "$_root" yes)"

    _rc=0
    _out="$(run_guard_arm "$_root" "$_plat" "$_installer" 'txn_begin; guard_arm' 2>"$_root/stderr")" || _rc=$?
    if [ "$_rc" != 0 ]; then
        fail "[$_plat] guard_arm exited $_rc against a well-formed payload: $(cat "$_root/stderr")"
        rm -rf "$_root"
        return
    fi

    [ -f "$_root/bin/guard.sh" ] ||
        fail "[$_plat] guard not placed on the root-secure surface (\$BIN_DIR/guard.sh)"
    cmp -s "$GUARD_SRC" "$_root/bin/guard.sh" ||
        fail "[$_plat] placed guard content does not match guard.sh"
    [ -d "$_root/libexec" ] &&
        fail "[$_plat] guard_arm recreated the retired libexec tree"

    case "$_plat" in
    Darwin)
        _plist="$_root/units/com.burrowee.gateway.guard.plist"
        [ -f "$_plist" ] || fail "[$_plat] guard plist not written"
        grep -q "<string>$_root/bin/guard.sh</string>" "$_plist" ||
            fail "[$_plat] plist does not name the root-secure guard copy"
        grep -q "payload/guard.sh" "$_plist" &&
            fail "[$_plat] plist names the PAYLOAD's guard.sh — root would exec a path the install left behind, not the placed copy"

        grep -q "$_root/var/gateway/install/" "$_plist" ||
            fail "[$_plat] plist does not pass the transaction dir to the guard"
        grep -q 'bootout system/com\.burrowee\.gateway\.guard$' "$_root/launchctl.calls" ||
            fail "[$_plat] guard_arm never boots out a stale guard job"
        grep -q "bootstrap system $_plist\$" "$_root/launchctl.calls" ||
            fail "[$_plat] guard_arm never bootstraps the guard plist"
        ;;
    Linux)
        grep -q -- '--unit=burrowee-gateway-guard' "$_root/systemd-run.calls" ||
            fail "[$_plat] systemd-run was never given the guard's unit name"
        grep -q -- '--collect' "$_root/systemd-run.calls" ||
            fail "[$_plat] systemd-run was not told --collect"
        grep -q "$_root/bin/guard.sh" "$_root/systemd-run.calls" ||
            fail "[$_plat] systemd-run was not pointed at the root-secure guard copy"
        grep -q "payload/guard.sh" "$_root/systemd-run.calls" &&
            fail "[$_plat] systemd-run was pointed at the PAYLOAD's guard.sh, not the placed copy"

        grep -q "$_root/var/gateway/install/" "$_root/systemd-run.calls" ||
            fail "[$_plat] systemd-run was not given the transaction dir"
        ;;
    esac

    printf '%s' "$_out" | grep -q 'guard armed' || fail "[$_plat] guard_arm printed no armed confirmation"
    rm -rf "$_root"
}

# THE REGRESSION: no guard.sh beside the installer must refuse, even with a
# decoy guard.sh sitting at the OLD, wrong location ($GW_HOME/guard.sh) —
# proving resolution is "$(dirname "$0")/guard.sh", never $GW_HOME. Run once
# per platform shape: the refusal happens before the platform case statement,
# but a resolution bug that silently found the decoy would behave differently
# per platform (Linux's systemd-run takes no unit FILE at all), so both are
# driven rather than assumed equivalent.
t_guard_arm_refuses_without_guard_beside_installer() {
    _plat="$1"
    _root="$(mktemp -d)"
    setup_root "$_root"
    _installer="$(stage_payload "$_root" no)"
    _home="$_root/home"
    _decoy_gw_home="$_home/.burrowee/gateway"
    mkdir -p "$_decoy_gw_home"
    cp "$GUARD_SRC" "$_decoy_gw_home/guard.sh"

    _rc=0
    run_guard_arm "$_root" "$_plat" "$_installer" 'txn_begin; guard_arm' "$_home" \
        >"$_root/stdout" 2>"$_root/stderr" || _rc=$?

    [ "$_rc" != 0 ] || fail "[$_plat] guard_arm succeeded with no guard.sh beside the installer"
    grep -q 'guard\.sh is not beside this installer' "$_root/stderr" ||
        fail "[$_plat] guard_arm's refusal message is missing or changed: $(cat "$_root/stderr")"
    [ ! -e "$_root/bin/guard.sh" ] ||
        fail "[$_plat] guard_arm placed a guard despite refusing — it read the \$GW_HOME decoy instead of resolving beside \$0"
    rm -rf "$_root"
}

# ---------------------------------------------------------------------------
# LOADED IS NOT RUNNING.
#
# `launchctl bootstrap` exiting 0 says launchd accepted the job; `systemd-run`
# exiting 0 says systemd accepted the transient unit. Neither says the process
# execed. A guard that dies immediately used to produce a GREEN INSTALL THAT
# RESTARTED NOTHING: the installer ran Phases 1-4, wrote phase=handoff to a
# process that was gone, polled a phase file nothing would ever advance,
# printed "the guard has not reported yet; it is still running and will finish"
# — false — and returned 0. New binaries on disk, old daemon running, success
# reported.
#
# guard.sh's first two statements write guard.pid and log "guard armed", before
# anything that can fail, so guard_arm polls for either one and refuses when
# neither appears. The supervisor stub here is told NOT to simulate the start,
# which is exactly the dead guard.
# ---------------------------------------------------------------------------
t_guard_arm_refuses_when_the_guard_never_starts() {
    _plat="$1"
    _root="$(mktemp -d)"
    setup_root "$_root"
    _installer="$(stage_payload "$_root" yes)"

    _rc=0
    RGA_START=no RGA_ARM_CEILING=2 \
        run_guard_arm "$_root" "$_plat" "$_installer" 'txn_begin; guard_arm' \
        >"$_root/stdout" 2>"$_root/stderr" || _rc=$?

    [ "$_rc" != 0 ] ||
        fail "[$_plat] guard_arm reported success for a guard that never started — the install would proceed and restart nothing"
    grep -q 'guard never started' "$_root/stderr" ||
        fail "[$_plat] guard_arm's dead-guard refusal does not say what happened: $(cat "$_root/stderr")"
    grep -q 'guard armed' "$_root/stdout" &&
        fail "[$_plat] guard_arm printed its armed confirmation for a guard that never started"
    rm -rf "$_root"
}

# ---------------------------------------------------------------------------
# A SECOND INSTALL MUST NOT BOOT OUT A LIVE GUARD.
#
# guard.pid was written from day one with the comment "so a second install can
# refuse to race a live guard", and nothing read it — while the Darwin arm
# unconditionally boots the guard LABEL out. A second install started while the
# first guard was mid-rollback therefore killed it between restoring the files
# and restarting the daemon: the stranding this whole design removes,
# manufactured by the design itself.
#
# The refusal is per transaction and needs BOTH halves — a live pid AND a
# non-terminal phase — so a finished guard's leftover pid file (or a recycled
# pid) cannot refuse installs forever. Both halves are driven below.
# ---------------------------------------------------------------------------
t_guard_arm_refuses_a_live_guard() {
    _plat="$1"
    _root="$(mktemp -d)"
    setup_root "$_root"
    _installer="$(stage_payload "$_root" yes)"

    # A live "guard" (this shell's own sleep) mid-rollback in an earlier
    # transaction.
    _old="$_root/var/gateway/install/20260830T010101Z"
    mkdir -p "$_old"
    sh -c 'sleep 20' &
    _live=$!
    printf '%s\n' "$_live" > "$_old/guard.pid"
    printf 'rolling-back\n' > "$_old/phase"

    _rc=0
    run_guard_arm "$_root" "$_plat" "$_installer" 'txn_begin; guard_arm' \
        >"$_root/stdout" 2>"$_root/stderr" || _rc=$?
    [ "$_rc" != 0 ] ||
        fail "[$_plat] guard_arm armed on top of a guard that is mid-rollback"
    grep -q 'still running' "$_root/stderr" ||
        fail "[$_plat] the concurrent-guard refusal does not say why: $(cat "$_root/stderr")"
    # And it refused BEFORE touching the supervisor, so the live guard's job
    # was never booted out.
    [ -f "$_root/launchctl.calls" ] && grep -q 'bootout' "$_root/launchctl.calls" &&
        fail "[$_plat] guard_arm booted a label out before refusing"

    # A TERMINAL earlier transaction with the same live pid must NOT refuse:
    # the pid file outlives the guard, and pids are recycled.
    printf 'ok\n' > "$_old/phase"
    _rc=0
    run_guard_arm "$_root" "$_plat" "$_installer" 'txn_begin; guard_arm' \
        >"$_root/stdout2" 2>"$_root/stderr2" || _rc=$?
    [ "$_rc" = 0 ] ||
        fail "[$_plat] guard_arm refused over a FINISHED transaction's stale guard.pid: $(cat "$_root/stderr2")"

    kill "$_live" 2>/dev/null || true
    wait "$_live" 2>/dev/null || true
    rm -rf "$_root"
}

# An unsupported platform is a DELIBERATE refusal with a message, not a warning
# and an unguarded install. There is no supervisor to hold the guard outside the
# operator's session, and this script's fresh path no longer restarts anything
# itself — so continuing would place binaries, hand off to nobody, and report
# success.
t_guard_arm_refuses_an_unsupported_platform() {
    _root="$(mktemp -d)"
    setup_root "$_root"
    _installer="$(stage_payload "$_root" yes)"

    _rc=0
    run_guard_arm "$_root" SunOS "$_installer" 'txn_begin; guard_arm' \
        >"$_root/stdout" 2>"$_root/stderr" || _rc=$?
    [ "$_rc" != 0 ] || fail "guard_arm continued unguarded on an unsupported platform"
    grep -q 'no launchd and no systemd' "$_root/stderr" ||
        fail "guard_arm's unsupported-platform refusal does not name the cause: $(cat "$_root/stderr")"
    grep -q 'nothing has been written yet' "$_root/stderr" ||
        fail "guard_arm's unsupported-platform refusal does not say the host is untouched"
    rm -rf "$_root"
}

# BURROWEE_NO_RESTART=1 must reach guard_arm and stop it there, leaving
# GUARD_ARMED at 0 — the flag's documented meaning ("stages without arming a
# restart") and, until this fix, the one thing it did not do on the default
# path: its only two readers were inside load_units, which the fresh flow no
# longer calls, so the guard armed and restarted anyway.
t_guard_arm_honours_no_restart() {
    _plat="$1"
    _root="$(mktemp -d)"
    setup_root "$_root"
    _installer="$(stage_payload "$_root" yes)"

    _rc=0
    _out="$(BURROWEE_NO_RESTART=1 run_guard_arm "$_root" "$_plat" "$_installer" \
        'txn_begin; guard_arm; echo "GUARD_ARMED=$GUARD_ARMED"' 2>"$_root/stderr")" || _rc=$?
    [ "$_rc" = 0 ] || fail "[$_plat] guard_arm failed under BURROWEE_NO_RESTART: $(cat "$_root/stderr")"
    printf '%s\n' "$_out" | grep -q 'GUARD_ARMED=0' ||
        fail "[$_plat] BURROWEE_NO_RESTART left GUARD_ARMED set — the handoff would still fire: $_out"
    [ ! -e "$_root/bin/guard.sh" ] ||
        fail "[$_plat] BURROWEE_NO_RESTART still placed the guard"
    [ ! -e "$_root/units/com.burrowee.gateway.guard.plist" ] ||
        fail "[$_plat] BURROWEE_NO_RESTART still wrote the guard plist"
    grep -q 'BURROWEE_NO_RESTART set' "$_root/stderr" ||
        fail "[$_plat] BURROWEE_NO_RESTART is honoured silently: $(cat "$_root/stderr")"
    rm -rf "$_root"
}

# keep_installer_copy must keep guard.sh at $GW_HOME too, off the SAME
# resolution guard_arm uses — a later units-only re-run's $0 IS the kept
# $GW_HOME/install.sh, and without this copy that run finds no guard beside it.
t_keep_installer_copy_copies_guard_sh() {
    _root="$(mktemp -d)"
    setup_root "$_root"
    _installer="$(stage_payload "$_root" yes)"
    _home="$_root/home"

    run_guard_arm "$_root" Linux "$_installer" 'keep_installer_copy' "$_home" >/dev/null 2>&1

    _gw_home="$_home/.burrowee/gateway"
    [ -f "$_gw_home/install.sh" ] || fail "keep_installer_copy regressed: install.sh is no longer kept at \$GW_HOME"
    [ -f "$_gw_home/guard.sh" ]   || fail "keep_installer_copy did not keep guard.sh at \$GW_HOME"
    cmp -s "$GUARD_SRC" "$_gw_home/guard.sh" || fail "the kept guard.sh copy does not match inner/gateway/guard.sh"
    rm -rf "$_root"
}

# keep_installer_copy must not fail an install merely because THIS bundle
# carries no guard.sh (an old bundle predating Task 5, or install.sh's own
# $GW_HOME self-copy re-run) — same tolerance as the migrations/ copy beside it.
t_keep_installer_copy_tolerates_missing_guard_sh() {
    _root="$(mktemp -d)"
    setup_root "$_root"
    _installer="$(stage_payload "$_root" no)"
    _home="$_root/home"

    _rc=0
    run_guard_arm "$_root" Linux "$_installer" 'keep_installer_copy' "$_home" >/dev/null 2>"$_root/stderr" || _rc=$?
    [ "$_rc" = 0 ] || fail "keep_installer_copy failed outright when the bundle carries no guard.sh: $(cat "$_root/stderr")"
    [ -f "$_home/.burrowee/gateway/install.sh" ] || fail "keep_installer_copy did not keep install.sh when guard.sh was absent"
    rm -rf "$_root"
}

for _plat in Darwin Linux; do
    t_guard_arm_finds_guard_beside_installer "$_plat"
    t_guard_arm_refuses_without_guard_beside_installer "$_plat"
    t_guard_arm_refuses_when_the_guard_never_starts "$_plat"
    t_guard_arm_refuses_a_live_guard "$_plat"
    t_guard_arm_honours_no_restart "$_plat"
done
t_guard_arm_refuses_an_unsupported_platform

t_keep_installer_copy_copies_guard_sh
t_keep_installer_copy_tolerates_missing_guard_sh

if [ "$fails" -ne 0 ]; then
    printf '%s: %d check(s) failed\n' "$0" "$fails" >&2
    exit 1
fi
printf 'ok: guard_arm resolves guard.sh beside the installer (Darwin + Linux)\n'

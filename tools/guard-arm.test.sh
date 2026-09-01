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
# shares: $BIN_DIR, the unit dir, both system roots, and the libexec
# destination guard_arm places its binary at.
setup_root() {
    mkdir -p "$1/bin" "$1/units" "$1/etc/gateway" "$1/var/gateway" "$1/libexec/burrowee"
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

# make_supervisor_stub <dir> <platform> <root> — the ONE supervisor command
# guard_arm actually drives for <platform>: launchctl on Darwin, systemd-run
# on Linux. Records argv and exits 0; never spawns anything. Real launchctl and
# systemd-run talk to the HOST's own init system — exactly the shared-machine
# side effect every stub in this suite exists to prevent.
make_supervisor_stub() {
    _ms_dir="$1"; _ms_plat="$2"; _ms_root="$3"
    case "$_ms_plat" in
    Darwin)
        cat > "$_ms_dir/launchctl" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$_ms_root/launchctl.calls"
exit 0
STUB
        chmod 755 "$_ms_dir/launchctl"
        ;;
    Linux)
        cat > "$_ms_dir/systemd-run" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$_ms_root/systemd-run.calls"
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
    make_supervisor_stub "$_rga_stub" "$_rga_plat" "$_rga_root"
    HOME="$_rga_home" \
    BURROWEE_SOURCE_ONLY=1 \
    PATH="$_rga_stub:$PATH" \
    BURROWEE_BIN_DIR="$_rga_root/bin" \
    BURROWEE_LAUNCHD_DIR="$_rga_root/units" \
    BURROWEE_SYSTEMD_DIR="$_rga_root/units" \
    BURROWEE_SYSTEM_CONFIG_DIR="$_rga_root/etc/gateway" \
    BURROWEE_SYSTEM_DATA_DIR="$_rga_root/var/gateway" \
    BURROWEE_LIBEXEC_DIR="$_rga_root/libexec/burrowee" \
    sh -c '. "$0"; eval "$1"' "$_rga_installer" "$_rga_snippet"
}

# guard_arm must find guard.sh beside the installer, place it at the libexec
# destination, and hand it to the right supervisor for the platform. Run once
# per platform shape (see the loop at the bottom) — do not copy-paste this
# body per platform.
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

    [ -f "$_root/libexec/burrowee/gateway-guard" ] ||
        fail "[$_plat] guard binary not placed at the libexec destination"
    cmp -s "$GUARD_SRC" "$_root/libexec/burrowee/gateway-guard" ||
        fail "[$_plat] placed guard binary content does not match guard.sh"

    case "$_plat" in
    Darwin)
        _plist="$_root/units/com.burrowee.gateway.guard.plist"
        [ -f "$_plist" ] || fail "[$_plat] guard plist not written"
        grep -q "$_root/libexec/burrowee/gateway-guard" "$_plist" ||
            fail "[$_plat] plist does not name the placed guard binary"
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
        grep -q "$_root/libexec/burrowee/gateway-guard" "$_root/systemd-run.calls" ||
            fail "[$_plat] systemd-run was not pointed at the placed guard binary"
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
    [ ! -e "$_root/libexec/burrowee/gateway-guard" ] ||
        fail "[$_plat] guard_arm placed a binary despite refusing — it read the \$GW_HOME decoy instead of resolving beside \$0"
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
done
t_keep_installer_copy_copies_guard_sh
t_keep_installer_copy_tolerates_missing_guard_sh

if [ "$fails" -ne 0 ]; then
    printf '%s: %d check(s) failed\n' "$0" "$fails" >&2
    exit 1
fi
printf 'ok: guard_arm resolves guard.sh beside the installer (Darwin + Linux)\n'

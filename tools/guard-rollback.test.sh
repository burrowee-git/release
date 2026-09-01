#!/bin/sh
# tools/guard-rollback.test.sh — drives inner/gateway/guard.sh against a fake
# supervisor and a fake host tree, and (Task 8) drives install.sh's own
# Phase 2 verification functions (verify_placement, verify_units) directly
# against install.sh's source. Nothing here touches a real launchd, systemd,
# binary or database.
#
#     sh tools/guard-rollback.test.sh
#     dash tools/guard-rollback.test.sh
#
# BOTH PLATFORM SHAPES, NOT JUST DARWIN. Task 4's guard-snapshot.test.sh was
# first written Darwin-only and had to be sent back for it: Burrowee gateways
# run on Linux, and a rollback path never driven against systemd is the whole
# point of this work left unverified on half the fleet. So every check here
# runs once per platform (see the loop at the bottom), driving whichever
# supervisor stub — launchctl or systemctl — the guard actually calls for that
# platform, the same way guard-snapshot.test.sh now parameterises its own
# snapshot checks. Assertion BODIES are written once and taken per-platform
# values from the helpers just below, rather than copy-pasted per platform.
# The Task 8 checks below follow the same discipline for verify_units, whose
# Darwin branch (a faked `plutil -lint`) has no real counterpart on this
# suite's own Linux CI box — see make_plutil_stub.
set -eu

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
GUARD="$HERE/inner/gateway/guard.sh"
fails=0
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }

# serve_unit_name <platform> — the serve unit's filename on <platform>, same
# mapping as guard-snapshot.test.sh.
serve_unit_name() {
    case "$1" in
    Darwin) echo com.burrowee.gateway.plist ;;
    Linux)  echo burrowee-gateway.service ;;
    esac
}

# supervisor_bin <root> <platform> — which stub file the guard actually
# invokes for <platform>: launchctl on Darwin, systemctl on Linux.
supervisor_bin() {
    case "$2" in
    Darwin) echo "$1/launchctl" ;;
    Linux)  echo "$1/systemctl" ;;
    esac
}

# supervisor_calls <root> <platform> — the log file the stub appends every
# invocation to.
supervisor_calls() {
    case "$2" in
    Darwin) echo "$1/launchctl.calls" ;;
    Linux)  echo "$1/systemctl.calls" ;;
    esac
}

# restart_verb <platform> — the call that means "the guard restarted the
# service": launchd's kickstart, systemd's restart.
restart_verb() {
    case "$1" in
    Darwin) echo kickstart ;;
    Linux)  echo restart ;;
    esac
}

# unsupervise_pattern <platform> <unit> — the ANCHORED call that would
# unsupervise the serve unit if the guard ever made it: launchd's bootout, or
# systemd's bare stop. Anchored to the SERVE unit only (a trailing `$`) so a
# later, legitimate updater unload (Task 10 — the updater is safe to unload,
# nothing routes through it) does not trip this check.
unsupervise_pattern() {
    case "$1" in
    Darwin) printf '%s\n' 'bootout system/com.burrowee.gateway$' ;;
    Linux)  printf 'stop %s$\n' "$2" ;;
    esac
}

# write_fake_bin <path> <marker> <version> — a fake serve binary that is both
# grep-able (the marker line, for the content assertions below) AND runnable:
# guard.sh's binary_version() actually execs `burrowee-gateway version` to
# learn what the just-placed build claims to be, so a plain marker-text file
# — non-executable content, no `version` reply — reads as "could not read the
# new binary's version stamp" and the guard rolls back on every run,
# including the one meant to succeed. A real, if tiny, script fixes both: the
# marker survives as a comment line, and `version` gets a real answer.
write_fake_bin() {
    _p="$1"; _marker="$2"; _ver="$3"
    cat > "$_p" <<STUB
#!/bin/sh
# $_marker
case "\$1" in
  version) echo "$_ver" ;;
esac
STUB
    chmod 755 "$_p"
}

# setup_fake_host <root> <platform> — a host tree with an old install in
# place, carrying the platform's own unit shape.
setup_fake_host() {
    _r="$1"; _plat="$2"
    mkdir -p "$_r/bin" "$_r/etc/gateway/identity" "$_r/var/gateway" "$_r/units"
    for b in burrowee burrowee-gateway burrowee-gateway-cli \
             burrowee-gateway-console burrowee-register burrowee-gateway-updater; do
        write_fake_bin "$_r/bin/$b" "OLD BINARY" v0.2.13
    done
    printf 'OLD KEY\n' > "$_r/etc/gateway/identity/relay_ed.key"
    printf 'OLD DB\n'  > "$_r/var/gateway/gateway.db"
    printf '<unit/>\n' > "$_r/units/$(serve_unit_name "$_plat")"
    printf '{"version":"v0.2.13","pid":1,"started_at":0}\n' > "$_r/var/gateway/running.json"
}

# fake_supervisor <root> <platform> <behaviour> — writes the stub the guard
# actually drives for <platform>. behaviour is "advance" (the restart makes
# running.json report the NEW version) or "dead" (the restart never changes
# running.json — the failing-new-build case).
fake_supervisor() {
    _r="$1"; _plat="$2"; _behaviour="$3"
    _bin="$(supervisor_bin "$_r" "$_plat")"
    _calls="$(supervisor_calls "$_r" "$_plat")"
    _verb="$(restart_verb "$_plat")"
    cat > "$_bin" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$_calls"
case "\$1" in
  $_verb)
    if [ "$_behaviour" = advance ]; then
      printf '{"version":"%s","pid":2,"started_at":0}\n' "\$(cat "$_r/newver")" \
        > "$_r/var/gateway/running.json"
    fi
    ;;
  print) exit 0 ;;
  is-active) exit 0 ;;
esac
exit 0
STUB
    chmod 755 "$_bin"
    : > "$_calls"
}

# make_txn <root> <platform> — a transaction directory with a snapshot already
# taken.
make_txn() {
    _r="$1"; _plat="$2"
    _t="$_r/var/gateway/install/20260831T140211Z"
    mkdir -p "$_t/snapshot/bin" "$_t/snapshot/units" "$_t/snapshot/config" "$_t/snapshot/data"
    cp "$_r"/bin/* "$_t/snapshot/bin/"
    cp "$_r/units/$(serve_unit_name "$_plat")" "$_t/snapshot/units/"
    cp -R "$_r/etc/gateway/." "$_t/snapshot/config/"
    cp "$_r/var/gateway/gateway.db" "$_t/snapshot/data/"
    printf 'stamp=20260831T140211Z\nrunning_version=v0.2.13\nconsistency=exact\n' > "$_t/manifest"
    printf 'v0.3.1\n' > "$_r/newver"
    printf '%s\n' "$_t"
}

run_guard() {
    _r="$1"; _txn="$2"; _plat="$3"
    GUARD_LAUNCHCTL="$_r/launchctl" \
    GUARD_SYSTEMCTL="$_r/systemctl" \
    GUARD_DEADLINE=10 GUARD_VERIFY_CEILING=3 GUARD_VERIFY_INTERVAL=1 \
    BURROWEE_BIN_DIR="$_r/bin" \
    BURROWEE_LAUNCHD_DIR="$_r/units" \
    BURROWEE_SYSTEMD_DIR="$_r/units" \
    BURROWEE_SYSTEM_CONFIG_DIR="$_r/etc/gateway" \
    BURROWEE_SYSTEM_DATA_DIR="$_r/var/gateway" \
    GUARD_UNAME="$_plat" \
    sh "$GUARD" "$_txn" >/dev/null 2>&1 || true
}

# A restart the new build survives ends 'ok', and never unsupervises the serve
# unit. Run once per platform shape (see the loop at the bottom) — do not
# copy-paste this body per platform.
t_guard_ok() {
    _plat="$1"
    _r="$(mktemp -d)"; setup_fake_host "$_r" "$_plat"; fake_supervisor "$_r" "$_plat" advance
    _t="$(make_txn "$_r" "$_plat")"
    write_fake_bin "$_r/bin/burrowee-gateway" "NEW BINARY v0.3.1" v0.3.1
    printf 'handoff\n' > "$_t/phase"
    run_guard "$_r" "$_t" "$_plat"

    _calls="$(supervisor_calls "$_r" "$_plat")"
    [ "$(cat "$_t/phase")" = ok ] || fail "[$_plat] phase = $(cat "$_t/phase"), want ok"
    grep -q 'NEW BINARY' "$_r/bin/burrowee-gateway" || fail "[$_plat] ok path clobbered the new binary"
    grep -q "$(restart_verb "$_plat")" "$_calls" || fail "[$_plat] guard never restarted the service"
    ! grep -q "$(unsupervise_pattern "$_plat" "$(serve_unit_name "$_plat")")" "$_calls" \
        || fail "[$_plat] guard unsupervised the serve unit"
    rm -rf "$_r"
}

# A restart the new build does NOT survive ends 'rolled-back', with the old
# binary restored and the daemon serving again. Run once per platform shape.
t_guard_rolls_back() {
    _plat="$1"
    _r="$(mktemp -d)"; setup_fake_host "$_r" "$_plat"; fake_supervisor "$_r" "$_plat" dead
    _t="$(make_txn "$_r" "$_plat")"
    write_fake_bin "$_r/bin/burrowee-gateway" "NEW BINARY v0.3.1" v0.3.1
    printf 'handoff\n' > "$_t/phase"
    run_guard "$_r" "$_t" "$_plat"

    [ "$(cat "$_t/phase")" = rolled-back ] || fail "[$_plat] phase = $(cat "$_t/phase"), want rolled-back"
    grep -q 'OLD BINARY' "$_r/bin/burrowee-gateway" || fail "[$_plat] rollback did not restore the old binary"
    rm -rf "$_r"
}

# ---------------------------------------------------------------------------
# Task 8 — Phase 2 (verify_placement / verify_units), run before anything is
# restarted. Two static checks that the brief itself specifies, plus
# behavioural coverage of the two functions against install.sh's own source,
# via BURROWEE_SOURCE_ONLY the same way guard-snapshot.test.sh already does.
# ---------------------------------------------------------------------------

GATEWAY_BINS="burrowee burrowee-gateway burrowee-gateway-cli burrowee-gateway-console burrowee-register burrowee-gateway-updater"

# Verification runs BEFORE anything is restarted, so a bad placement is caught
# while the old daemon is still serving and the operator is still connected —
# the cheap failure, not the expensive one.
#
# UPDATED FOR TASK 9: this used to anchor to `finish_with_updater_verdict`
# because `txn_phase handoff` did not exist yet — Task 9 is what writes it.
# Now that it does, this asserts the real thing the brief always meant:
# verify_placement runs after Phase 1 begins (`txn_phase replacing`) and
# before the handoff that puts the restart in the guard's hands.
t_verify_precedes_handoff() {
    _f="$HERE/inner/gateway/install.sh"
    _phase1="$(grep -n '^txn_phase replacing$' "$_f" | head -1 | cut -d: -f1)"
    _v="$(grep -n 'verify_placement || {' "$_f" | head -1 | cut -d: -f1)"
    _end="$(grep -n '^txn_phase handoff$' "$_f" | head -1 | cut -d: -f1)"
    [ -n "$_phase1" ] || { fail "install.sh never reaches txn_phase replacing"; return; }
    [ -n "$_v" ]      || { fail "install.sh never calls verify_placement"; return; }
    [ -n "$_end" ]    || { fail "install.sh never reaches txn_phase handoff"; return; }
    [ "$_phase1" -lt "$_v" ] || fail "verify_placement (line $_v) runs before Phase 1 (line $_phase1)"
    [ "$_v" -lt "$_end" ]    || fail "verify_placement (line $_v) runs after txn_phase handoff (line $_end)"
}

# A non-interactive install must NOT block on a prompt: console pushes, CI and
# `curl … | sh` have no tty, and today they restart unconditionally. A
# blocking prompt there would break every automated install.
#
# Comment lines are stripped before either grep: consent_to_sever's own header
# talks ABOUT has_tty at length (why it is safe to assume a real /dev/tty open
# will succeed once has_tty has already proved one exists), and a check that
# did not strip comments would pass on that prose alone even with the actual
# gate deleted from the CODE — proven by mutation while writing this test.
t_consent_is_tty_gated() {
    _f="$HERE/inner/gateway/install.sh"
    grep -q 'consent_to_sever' "$_f" || { fail "install.sh never calls consent_to_sever"; return; }
    _body="$(sed -n '/^consent_to_sever() {/,/^}/p' "$_f" | grep -v '^[[:space:]]*#')"
    printf '%s\n' "$_body" | grep -q 'has_tty' \
        || fail "consent_to_sever does not gate on has_tty"
    printf '%s\n' "$_body" | grep -q 'BURROWEE_ASSUME_YES' \
        || fail "consent_to_sever offers no non-interactive override"
}

# The reconnect instruction must be printed BEFORE the handoff — printing it
# after is printing it into a connection that may already be gone.
#
# Anchored to the EXACT unconditional echo, at column 0 in the flow (never
# inside a function body), not a bare substring search for "guard-status": a
# plain substring match finds consent_to_sever's own prompt text AND
# reattach's own messages first — both are function bodies that sit earlier
# in the file than the flow that calls them, and both mention guard-status,
# so a substring check "passes" against either one even with the actual
# unconditional echo below deleted. Caught only by mutation while writing
# this test; the exact-line anchor is what closes it.
t_reconnect_line_precedes_handoff() {
    _f="$HERE/inner/gateway/install.sh"
    _r="$(grep -n '^echo "    burrowee gateway service guard-status"$' "$_f" | head -1 | cut -d: -f1)"
    _h="$(grep -n '^txn_phase handoff$' "$_f" | head -1 | cut -d: -f1)"
    [ -n "$_r" ] || { fail "install.sh never prints the unconditional guard-status reconnect line ahead of the handoff"; return; }
    [ -n "$_h" ] || { fail "install.sh never reaches txn_phase handoff"; return; }
    [ "$_r" -lt "$_h" ] || fail "the reconnect line (line $_r) is printed after the handoff (line $_h)"
}

# A verification failure must restore the snapshot rather than hand off.
t_verify_failure_restores() {
    grep -q 'verify_placement || {' "$HERE/inner/gateway/install.sh" \
        || fail "a failed verify_placement does not branch to a restore"
}

# make_sudo_stub <dir> — a pass-through `sudo`, same shape as
# guard-snapshot.test.sh's: install.sh's run_root always tries to elevate, and
# these fixtures are tmpdirs the test process already owns.
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
# guard-snapshot.test.sh's, so verify_units' Darwin/Linux branch is chosen
# deliberately rather than by whatever this suite happens to run on.
make_uname_stub() {
    mkdir -p "$1"
    _plat="$2"
    cat > "$1/uname" <<STUB
#!/bin/sh
if [ "\$1" = "-s" ]; then echo $_plat; else /usr/bin/uname "\$@"; fi
STUB
    chmod 755 "$1/uname"
}

# make_plutil_stub <dir> <exit-code> — a fake `plutil` so verify_units' Darwin
# lint branch is exercised even from this suite's Linux CI box, which has no
# real plutil at all — verify_units' own `command -v plutil` guard exists for
# exactly that box, and without a stub the branch behind it would never run
# from here. The exit code alone decides "valid" vs "not a valid plist";
# a stub standing in for the check has no real plist syntax to validate.
make_plutil_stub() {
    mkdir -p "$1"
    cat > "$1/plutil" <<STUB
#!/bin/sh
exit $2
STUB
    chmod 755 "$1/plutil"
}

# install_stub_dir <root> — the one fake-PATH directory every install.sh
# function test below shares, so a test that needs an extra fake (plutil)
# can drop it in after setup_install_stubs without a second helper that
# regenerates the directory out from under it.
install_stub_dir() { printf '%s\n' "$1/.stub"; }

# setup_install_stubs <root> <platform> — the baseline fake PATH every
# verify_placement/verify_units test needs: pass-through sudo (so run_root
# never blocks on a real elevation prompt) and pinned uname. The pass-through
# sudo also means have_real_root answers "no" here, same as it does under
# the Go install_test harness — so verify_placement's root-secure check is
# skipped in these fixtures exactly as it is there, and is not re-proven by
# this suite (core/binary's IsRootSecure suite, plus install_test's own
# root_exec_test.go, already own that predicate).
setup_install_stubs() {
    _r="$1"; _plat="$2"
    _stub="$(install_stub_dir "$_r")"
    make_sudo_stub "$_stub"
    make_uname_stub "$_stub" "$_plat"
}

# run_install_snippet <root> <cwd> <snippet> — source install.sh
# (BURROWEE_SOURCE_ONLY short-circuits the mode dispatch, same as
# guard-snapshot.test.sh) with cwd at <cwd> — verify_placement's archive
# comparison reads "./$b" relative to it — then run <snippet> against its
# functions. stdout and stderr are merged so a failure message can be
# grepped from the captured output.
run_install_snippet() {
    _r="$1"; _cwd="$2"; _snippet="$3"
    _stub="$(install_stub_dir "$_r")"
    (
        cd "$_cwd" && \
        BURROWEE_SOURCE_ONLY=1 \
        PATH="$_stub:$PATH" \
        BURROWEE_BIN_DIR="$_r/bin" \
        BURROWEE_LAUNCHD_DIR="$_r/units" \
        BURROWEE_SYSTEMD_DIR="$_r/units" \
        BURROWEE_SYSTEM_CONFIG_DIR="$_r/etc/gateway" \
        BURROWEE_SYSTEM_DATA_DIR="$_r/var/gateway" \
        sh -c ". '$HERE/inner/gateway/install.sh'; $_snippet" 2>&1
    )
}

# run_reattach <root> <phase> <ceiling> <interval> — write <phase> into a
# fresh transaction's phase file, then run reattach() against it through the
# same BURROWEE_SOURCE_ONLY seam run_install_snippet uses. reattach needs no
# tty and no real supervisor — it only ever reads a phase file — so this is
# the same shape as every verify_placement/verify_units check above, not a
# new harness.
#
# REATTACH_CEILING/REATTACH_INTERVAL are exported BEFORE install.sh is
# sourced, because install.sh reads them into shell variables with `${VAR:-…}`
# defaults at source time — an env var set that way is exactly what a default
# expansion picks up. TXN_DIR is the opposite: install.sh unconditionally
# assigns `TXN_DIR=""` at its own top level (txn_begin is what sets it for
# real, and this test never calls txn_begin), so an exported TXN_DIR would be
# clobbered the instant the script is sourced. It is set in the SNIPPET,
# after sourcing, same as TXN_STAMP.
run_reattach() {
    _r="$1"; _phase="$2"; _ceiling="$3"; _interval="$4"
    _txn="$_r/txn"
    rm -rf "$_txn"; mkdir -p "$_txn"
    printf '%s\n' "$_phase" > "$_txn/phase"
    _stub="$(install_stub_dir "$_r")"
    (
        cd "$_r" && \
        BURROWEE_SOURCE_ONLY=1 \
        PATH="$_stub:$PATH" \
        BURROWEE_BIN_DIR="$_r/bin" \
        BURROWEE_LAUNCHD_DIR="$_r/units" \
        BURROWEE_SYSTEMD_DIR="$_r/units" \
        BURROWEE_SYSTEM_CONFIG_DIR="$_r/etc/gateway" \
        BURROWEE_SYSTEM_DATA_DIR="$_r/var/gateway" \
        REATTACH_CEILING="$_ceiling" \
        REATTACH_INTERVAL="$_interval" \
        sh -c ". '$HERE/inner/gateway/install.sh'; TXN_DIR='$_txn'; TXN_STAMP=teststamp; reattach" 2>&1
    )
}

# write_archive_and_placement <root> — an archive dir and a $BIN_DIR that
# agree byte-for-byte on every name in $GATEWAY_BINS: the passing baseline
# every verify_placement check below starts from and mutates one property
# away from.
write_archive_and_placement() {
    _r="$1"
    mkdir -p "$_r/archive" "$_r/bin"
    for b in $GATEWAY_BINS; do
        printf '#!/bin/sh\necho %s\n' "$b" > "$_r/archive/$b"
        chmod 755 "$_r/archive/$b"
        cp "$_r/archive/$b" "$_r/bin/$b"
    done
}

# verify_placement's whole job is proving the mv landed the bytes staged from
# the archive, not merely that a file exists at $BIN_DIR — a good install
# (matching bytes, executable) must pass. The root-secure check does not fire
# in this fixture at all (see setup_install_stubs above).
t_verify_placement_passes_on_matching_install() {
    _r="$(mktemp -d)"
    setup_install_stubs "$_r" Linux
    write_archive_and_placement "$_r"
    _rc=0
    _out="$(run_install_snippet "$_r" "$_r/archive" 'verify_placement')" || _rc=$?
    [ "$_rc" -eq 0 ] || fail "verify_placement rejected a correctly placed install: $_out"
    rm -rf "$_r"
}

# Mutation proof: corrupt exactly one placed binary so its bytes diverge from
# the archive copy it was supposedly moved from, and confirm verify_placement
# actually notices — a check that never compared content would pass this
# fixture just as happily as the one above.
t_verify_placement_catches_corrupted_binary() {
    _r="$(mktemp -d)"
    setup_install_stubs "$_r" Linux
    write_archive_and_placement "$_r"
    printf '#!/bin/sh\necho corrupted\n' > "$_r/bin/burrowee-gateway"
    chmod 755 "$_r/bin/burrowee-gateway"
    _rc=0
    _out="$(run_install_snippet "$_r" "$_r/archive" 'verify_placement')" || _rc=$?
    [ "$_rc" -ne 0 ] || fail "verify_placement passed a placed binary whose bytes do not match the archive"
    printf '%s\n' "$_out" | grep -q 'does not match the archive copy' \
        || fail "verify_placement's failure did not name the mismatch: $_out"
    rm -rf "$_r"
}

# A binary the archive shipped but $BIN_DIR never received must fail too —
# the archive comparison only runs once a file is confirmed present.
t_verify_placement_catches_missing_binary() {
    _r="$(mktemp -d)"
    setup_install_stubs "$_r" Linux
    write_archive_and_placement "$_r"
    rm -f "$_r/bin/burrowee-register"
    _rc=0
    _out="$(run_install_snippet "$_r" "$_r/archive" 'verify_placement')" || _rc=$?
    [ "$_rc" -ne 0 ] || fail "verify_placement passed with burrowee-register missing from \$BIN_DIR"
    printf '%s\n' "$_out" | grep -q 'burrowee-register is missing' \
        || fail "verify_placement's failure did not name the missing binary: $_out"
    rm -rf "$_r"
}

# serve_unit_names <platform> — both unit files verify_units checks for
# <platform>: serve + updater.
serve_unit_names() {
    case "$1" in
    Darwin) printf '%s\n' com.burrowee.gateway.plist com.burrowee.gateway.updater.plist ;;
    Linux)  printf '%s\n' burrowee-gateway.service burrowee-gateway-updater.service ;;
    esac
}

# write_unit_fixture <root> <platform> — both unit files verify_units checks
# for <platform>, plus an executable ExecStart target: the passing baseline
# every verify_units check below starts from and mutates one property away
# from.
write_unit_fixture() {
    _r="$1"; _plat="$2"
    mkdir -p "$_r/units" "$_r/bin"
    for _u in $(serve_unit_names "$_plat"); do
        case "$_plat" in
        Darwin) printf '<?xml version="1.0"?><plist version="1.0"><dict/></plist>\n' > "$_r/units/$_u" ;;
        Linux)  printf '[Service]\nExecStart=/usr/local/bin/burrowee-gateway\n' > "$_r/units/$_u" ;;
        esac
    done
    printf '#!/bin/sh\necho burrowee-gateway\n' > "$_r/bin/burrowee-gateway"
    chmod 755 "$_r/bin/burrowee-gateway"
}

# A fully rendered install — both units present, the serve binary executable
# — must pass verify_units, on both platform shapes. Darwin additionally runs
# through a faked `plutil -lint` (make_plutil_stub): the real macOS tool does
# not exist on the Linux CI box this suite runs on, but the branch that calls
# it does, and the stub is what lets that branch be driven from here.
t_verify_units_passes() {
    _plat="$1"
    _r="$(mktemp -d)"
    setup_install_stubs "$_r" "$_plat"
    write_unit_fixture "$_r" "$_plat"
    [ "$_plat" = Darwin ] && make_plutil_stub "$(install_stub_dir "$_r")" 0
    _rc=0
    _out="$(run_install_snippet "$_r" "$_r" 'verify_units')" || _rc=$?
    [ "$_rc" -eq 0 ] || fail "[$_plat] verify_units rejected a correctly rendered install: $_out"
    rm -rf "$_r"
}

# Either unit file missing must fail — a unit that was never rendered is
# exactly the state that looks like a clean install right up until the
# restart.
t_verify_units_fails_when_unit_missing() {
    _plat="$1"
    _r="$(mktemp -d)"
    setup_install_stubs "$_r" "$_plat"
    write_unit_fixture "$_r" "$_plat"
    [ "$_plat" = Darwin ] && make_plutil_stub "$(install_stub_dir "$_r")" 0
    _u="$(serve_unit_names "$_plat" | head -1)"
    rm -f "$_r/units/$_u"
    _rc=0
    _out="$(run_install_snippet "$_r" "$_r" 'verify_units')" || _rc=$?
    [ "$_rc" -ne 0 ] || fail "[$_plat] verify_units passed with $_u missing"
    printf '%s\n' "$_out" | grep -q "$_u is missing" \
        || fail "[$_plat] verify_units's failure did not name $_u: $_out"
    rm -rf "$_r"
}

# The ExecStart target check is platform-independent — a unit that parses
# fine but names a binary that is not there or not executable is the failure
# mode that looks clean right up until the restart.
t_verify_units_fails_when_exec_target_not_executable() {
    _plat="$1"
    _r="$(mktemp -d)"
    setup_install_stubs "$_r" "$_plat"
    write_unit_fixture "$_r" "$_plat"
    [ "$_plat" = Darwin ] && make_plutil_stub "$(install_stub_dir "$_r")" 0
    chmod 644 "$_r/bin/burrowee-gateway"
    _rc=0
    _out="$(run_install_snippet "$_r" "$_r" 'verify_units')" || _rc=$?
    [ "$_rc" -ne 0 ] || fail "[$_plat] verify_units passed with a non-executable ExecStart target"
    printf '%s\n' "$_out" | grep -q 'is not executable' \
        || fail "[$_plat] verify_units's failure did not name the ExecStart target: $_out"
    rm -rf "$_r"
}

# Darwin-only mutation proof: a plist that fails to lint must fail
# verify_units even though the file is present — a presence-only check would
# pass this fixture just as happily as a well-formed one.
t_verify_units_darwin_fails_when_plist_invalid() {
    _r="$(mktemp -d)"
    setup_install_stubs "$_r" Darwin
    write_unit_fixture "$_r" Darwin
    make_plutil_stub "$(install_stub_dir "$_r")" 1
    _rc=0
    _out="$(run_install_snippet "$_r" "$_r" 'verify_units')" || _rc=$?
    [ "$_rc" -ne 0 ] || fail "verify_units passed a plist that fails to lint"
    printf '%s\n' "$_out" | grep -q 'is not a valid plist' \
        || fail "verify_units's failure did not name the invalid plist: $_out"
    rm -rf "$_r"
}

# ---------------------------------------------------------------------------
# reattach() behavioural coverage (Task 9, fix round 1). New, non-trivial
# logic — three terminal phases mapped to three distinct exit codes, plus a
# timeout fallback — that was previously covered only structurally (does the
# function exist, does it mention has_tty) and bypassed entirely in the Go
# suite via REATTACH_CEILING=0. This is the verdict mapping an operator
# actually reads to learn whether their host came back; it needs its own
# behavioural proof, not just a source-text check.
# ---------------------------------------------------------------------------

# The three terminal phases map to the three exit codes reattach's own header
# documents, and rolled-back/failed must both point the operator at
# guard-status — the one place they can find out what actually happened once
# they reconnect.
t_reattach_maps_terminal_phases_to_exit_codes() {
    _r="$(mktemp -d)"
    setup_install_stubs "$_r" Linux

    _rc=0; _out="$(run_reattach "$_r" ok 2 1)" || _rc=$?
    [ "$_rc" -eq 0 ] || fail "reattach with phase=ok exited $_rc, want 0: $_out"
    printf '%s\n' "$_out" | grep -q 'serving the new build' \
        || fail "reattach's ok output does not say the gateway is serving: $_out"

    _rc=0; _out="$(run_reattach "$_r" rolled-back 2 1)" || _rc=$?
    [ "$_rc" -eq 1 ] || fail "reattach with phase=rolled-back exited $_rc, want 1: $_out"
    printf '%s\n' "$_out" | grep -q 'guard-status' \
        || fail "reattach's rolled-back output does not point at guard-status: $_out"

    _rc=0; _out="$(run_reattach "$_r" failed 2 1)" || _rc=$?
    [ "$_rc" -eq 2 ] || fail "reattach with phase=failed exited $_rc, want 2: $_out"
    printf '%s\n' "$_out" | grep -q 'guard-status' \
        || fail "reattach's failed output does not point at guard-status: $_out"

    rm -rf "$_r"
}

# A phase that never reaches a terminal state — whether because the guard is
# still legitimately working, or because a read caught the phase file
# mid-write (a torn value; the guard's own default response to an
# unrecognised phase is to roll back, but that is guard.sh's call, not
# reattach's) — must never be mistaken for one. reattach's own logic makes no
# distinction between "still pending" and "garbage": both fall through every
# case arm identically and are handled by the same poll-then-give-up path, so
# one garbage value exercises both. Giving up must be exit 0 (this session
# not reattaching does not mean the install failed) with the honest
# "has not reported yet" message, once the ceiling elapses.
t_reattach_times_out_on_an_unrecognised_phase() {
    _r="$(mktemp -d)"
    setup_install_stubs "$_r" Linux

    _rc=0
    _out="$(run_reattach "$_r" "garbage-not-a-real-phase" 2 1)" || _rc=$?
    [ "$_rc" -eq 0 ] || fail "reattach timing out on an unrecognised phase exited $_rc, want 0: $_out"
    printf '%s\n' "$_out" | grep -q 'has not reported yet' \
        || fail "reattach did not report giving up on an unrecognised phase: $_out"

    rm -rf "$_r"
}

for _plat in Darwin Linux; do
    t_guard_ok "$_plat"
    t_guard_rolls_back "$_plat"
    t_verify_units_passes "$_plat"
    t_verify_units_fails_when_unit_missing "$_plat"
    t_verify_units_fails_when_exec_target_not_executable "$_plat"
done

t_verify_precedes_handoff
t_consent_is_tty_gated
t_reconnect_line_precedes_handoff
t_verify_failure_restores
t_verify_placement_passes_on_matching_install
t_verify_placement_catches_corrupted_binary
t_verify_placement_catches_missing_binary
t_verify_units_darwin_fails_when_plist_invalid
t_reattach_maps_terminal_phases_to_exit_codes
t_reattach_times_out_on_an_unrecognised_phase

if [ "$fails" -ne 0 ]; then
    printf '%s: %d check(s) failed\n' "$0" "$fails" >&2
    exit 1
fi
printf 'ok: guard reaches ok and rolled-back correctly, and Phase 2 verification catches a bad placement (Darwin + Linux)\n'

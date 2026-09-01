#!/bin/sh
# tools/guard-rollback.test.sh — drives inner/gateway/guard.sh against a fake
# supervisor and a fake host tree, and (Task 8) drives install.sh's own
# Phase 2 verification functions (verify_placement, verify_units) directly
# against install.sh's source. Nothing here touches a real launchd, systemd,
# binary or database.
#
# (Task 10) also drives the guard's post-success work — the stale-binary
# sweep via the root-secure $BIN_DIR/install.sh, the updater advance, snapshot
# retention, and the deadline exit, the third of the watch loop's three ways
# out (the first two, handoff->ok and installer-died, are covered by
# t_guard_ok and tools/guard-installer-death.test.sh respectively).
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

# updater_unit_name <platform> — the updater unit's filename on <platform>,
# the same mapping snapshot_take uses.
updater_unit_name() {
    case "$1" in
    Darwin) echo com.burrowee.gateway.updater.plist ;;
    Linux)  echo burrowee-gateway-updater.service ;;
    esac
}

# updater_advance_call <platform> — the exact recorded call that means "the
# guard started (or restarted) the updater": launchd's kickstart, systemd's
# restart, on the UPDATER label/unit specifically (never the bare serve one —
# unsupervise_pattern above already anchors that check separately).
updater_advance_call() {
    case "$1" in
    Darwin) printf '%s\n' 'kickstart -k system/com.burrowee.gateway.updater' ;;
    Linux)  printf '%s\n' 'restart burrowee-gateway-updater.service' ;;
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

# run_guard <root> <txn> <platform> [deadline] — deadline defaults to 10s,
# long enough that a normal ok/rolled-back run never comes close to it;
# t_guard_deadline_exceeded overrides it down to exercise the deadline branch
# itself in a couple of seconds instead of ten.
#
# GUARD_RC carries the guard's own EXIT STATUS out to the caller, because the
# status is half the contract (0 ok · 1 rolled-back · 2 failed) and the phase
# file is the other half — the two can disagree, and one bug made them do
# exactly that: apply_retention's prune loop returned 1 under `set -eu`, killing
# the guard after `phase ok` was already written, so the transaction read "ok"
# while the process reported "rolled-back" to anything watching. Assertions on
# the phase alone cannot see that.
GUARD_RC=0
run_guard() {
    _r="$1"; _txn="$2"; _plat="$3"; _deadline="${4:-10}"

    GUARD_LAUNCHCTL="$_r/launchctl" \
    GUARD_SYSTEMCTL="$_r/systemctl" \
    GUARD_DEADLINE="$_deadline" GUARD_VERIFY_CEILING=3 GUARD_VERIFY_INTERVAL=1 \
    BURROWEE_BIN_DIR="$_r/bin" \
    BURROWEE_LAUNCHD_DIR="$_r/units" \
    BURROWEE_SYSTEMD_DIR="$_r/units" \
    BURROWEE_SYSTEM_CONFIG_DIR="$_r/etc/gateway" \
    BURROWEE_SYSTEM_DATA_DIR="$_r/var/gateway" \
    GUARD_UNAME="$_plat" \
    sh "$GUARD" "$_txn" >/dev/null 2>&1 && GUARD_RC=0 || GUARD_RC=$?
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
# Task 10 — the guard's post-success work: the stale-binary sweep (via the
# root-secure $BIN_DIR/install.sh, never a per-user $GW_HOME copy and never
# `service install`), the updater advance, snapshot retention, and the
# deadline exit. Run once per platform shape unless noted.
# ---------------------------------------------------------------------------

# The updater unit is rendered by install.sh but never started on a fresh
# install — Task 7 removed load_units, which used to be what started it, from
# the foreground flow entirely. Restoring it is this guard's job, and only
# after the serve daemon itself has already proven up (t_guard_ok already
# covers that ordering for the serve restart; this covers it for the
# updater).
t_guard_ok_advances_updater() {
    _plat="$1"
    _r="$(mktemp -d)"; setup_fake_host "$_r" "$_plat"; fake_supervisor "$_r" "$_plat" advance
    _t="$(make_txn "$_r" "$_plat")"
    write_fake_bin "$_r/bin/burrowee-gateway" "NEW BINARY v0.3.1" v0.3.1
    printf 'handoff\n' > "$_t/phase"
    run_guard "$_r" "$_t" "$_plat"

    _calls="$(supervisor_calls "$_r" "$_plat")"
    [ "$(cat "$_t/phase")" = ok ] || fail "[$_plat] phase = $(cat "$_t/phase"), want ok"
    grep -q "$(updater_advance_call "$_plat")" "$_calls" \
        || fail "[$_plat] the updater was never advanced after a verified restart; calls:
$(cat "$_calls")"
    rm -rf "$_r"
}

# The stale-binary sweep must run via the ROOT-SECURE installer copy at
# $BIN_DIR/install.sh — the one ensure_root_exec_surface places (root-owned,
# verified non-root-unwritable all the way to /) on every real install —
# never a per-user $GW_HOME copy, and never by re-entering install.sh as
# `burrowee-gateway-cli service install` (which would arm a SECOND guard
# inside this one's own success path).
#
# CRITICAL fix, review round 1: the first version of this test (and of
# guard.sh) sourced a per-user $GW_HOME copy, reached via a gw_home= manifest
# field. $GW_HOME resolves from the INVOKING OPERATOR's $HOME and
# keep_installer_copy writes it with a plain `cp`, not run_root — writable by
# that operator, or by anything running as them, at any time afterwards.
# Sourcing that path as root turned "compromise one non-root account" into
# unattended root code execution on the next successful restart. Both the
# manifest field and the $GW_HOME sourcing are gone; this test now proves the
# corrected seam instead.
#
# This drives the REAL install.sh, not a stand-in, because the claim under
# test is that guard.sh's sourcing actually reaches the real function, with
# the right $BIN_DIR, not merely that some function got called.
t_guard_ok_sweeps_stale_bins() {
    _plat="$1"
    _r="$(mktemp -d)"; setup_fake_host "$_r" "$_plat"; fake_supervisor "$_r" "$_plat" advance
    _t="$(make_txn "$_r" "$_plat")"
    write_fake_bin "$_r/bin/burrowee-gateway" "NEW BINARY v0.3.1" v0.3.1

    # Same layout ensure_root_exec_surface leaves under $BIN_DIR on a real
    # host: install.sh itself, plus migrations/ beside it.
    mkdir -p "$_r/bin/migrations"
    cp "$HERE/inner/gateway/install.sh" "$_r/bin/install.sh"
    # A recording stand-in for the shipped library — same shape as the Go
    # suite's stageSweepLib (inner/gateway/install_test/stale_user_bins_test.go):
    # the deletion itself is that library's own contract, tested there;
    # recording the call and its environment is what this seam owns.
    cat > "$_r/bin/migrations/lib_stale_user_bins.sh" <<STUB
STALE_USER_BINS="\$BINS"
remove_stale_user_bins() {
    printf 'SWEEP_CALLED BIN_DIR=%s\n' "\$BIN_DIR" >> "$_r/sweep.calls"
}
STUB

    printf 'handoff\n' > "$_t/phase"
    run_guard "$_r" "$_t" "$_plat"

    [ "$(cat "$_t/phase")" = ok ] || fail "[$_plat] phase = $(cat "$_t/phase"), want ok"
    [ -f "$_r/sweep.calls" ] && grep -q 'SWEEP_CALLED' "$_r/sweep.calls" \
        || fail "[$_plat] the sweep never ran via the root-secure \$BIN_DIR/install.sh (guard.log: $(cat "$_t/guard.log" 2>/dev/null))"
    grep -q "BIN_DIR=$_r/bin$" "$_r/sweep.calls" 2>/dev/null \
        || fail "[$_plat] the sweep ran with the wrong \$BIN_DIR: $(cat "$_r/sweep.calls" 2>/dev/null)"
    rm -rf "$_r"
}

# A restart the new build never survives (verify_serving times out on the new
# version, forcing a deadline is unnecessary to prove that path — t_guard_ok
# already covers it) is not what this checks. This is the THIRD way out of
# the watch loop: nothing ever hands off, and nothing ever dies — the
# installer sits at a non-terminal phase indefinitely (a genuinely wedged
# migration), and the guard must not hold the host hostage forever. A short
# GUARD_DEADLINE makes the branch reachable in a couple of seconds rather than
# the production default of 900.
# Run in the BACKGROUND, not through run_guard: this test pins the ceiling
# ARITHMETIC itself, not merely the eventual outcome. A mutation that drops
# the elapsed-time subtraction entirely (comparing the raw epoch clock to
# DEADLINE instead of "now minus start") still ends at phase=rolled-back
# eventually — the outcome-only assertions below would not catch it — but it
# fires on the very first loop tick instead of after the deadline, which the
# early-phase check below does catch.
t_guard_deadline_exceeded() {
    _plat="$1"
    _deadline=4
    _r="$(mktemp -d)"; setup_fake_host "$_r" "$_plat"; fake_supervisor "$_r" "$_plat" dead
    _t="$(make_txn "$_r" "$_plat")"
    write_fake_bin "$_r/bin/burrowee-gateway" "NEW BINARY v0.3.1" v0.3.1
    printf 'replacing\n' > "$_t/phase"

    # The installer is still ALIVE throughout — this must be the deadline
    # branch firing, not the installer-died branch (that one is
    # tools/guard-installer-death.test.sh's job).
    sh -c 'sleep 30' &
    _ipid=$!
    printf '%s\n' "$_ipid" > "$_t/installer.pid"

    GUARD_LAUNCHCTL="$_r/launchctl" \
    GUARD_SYSTEMCTL="$_r/systemctl" \
    GUARD_DEADLINE="$_deadline" GUARD_VERIFY_CEILING=2 GUARD_VERIFY_INTERVAL=1 \
    BURROWEE_BIN_DIR="$_r/bin" \
    BURROWEE_LAUNCHD_DIR="$_r/units" \
    BURROWEE_SYSTEMD_DIR="$_r/units" \
    BURROWEE_SYSTEM_CONFIG_DIR="$_r/etc/gateway" \
    BURROWEE_SYSTEM_DATA_DIR="$_r/var/gateway" \
    GUARD_UNAME="$_plat" \
    sh "$GUARD" "$_t" >/dev/null 2>&1 &
    _gpid=$!

    # Halfway into a 4s deadline: the correct arithmetic has not fired yet.
    sleep 2
    _early="$(cat "$_t/phase")"

    wait "$_gpid" 2>/dev/null || true
    kill "$_ipid" 2>/dev/null || true
    wait "$_ipid" 2>/dev/null || true

    [ "$_early" = replacing ] \
        || fail "[$_plat] phase was already '$_early' 2s into a ${_deadline}s deadline — the ceiling arithmetic fired too early"
    [ "$(cat "$_t/phase")" = rolled-back ] \
        || fail "[$_plat] phase = $(cat "$_t/phase"), want rolled-back after the deadline"
    grep -q 'OLD BINARY' "$_r/bin/burrowee-gateway" \
        || fail "[$_plat] the deadline rollback did not restore the old binary"
    grep -q 'deadline.*exceeded' "$_t/guard.log" 2>/dev/null \
        || fail "[$_plat] guard.log does not record why it rolled back"
    rm -rf "$_r"
}

# ---------------------------------------------------------------------------
# I5 — the transient LaunchDaemon removes its OWN plist, on every exit path.
#
# The design said "transient LaunchDaemon, RunAtLoad, KeepAlive false, removes
# its own plist"; it did not remove it. A plist left in /Library/LaunchDaemons
# is RunAtLoad, so launchd re-execs `gateway-guard <that transaction dir>` at
# EVERY BOOT. A terminal transaction exits harmlessly at the watch loop's
# "already terminal" arm — but a NON-terminal one (power lost mid-install)
# hands the boot-time guard a stale installer.pid that is certainly dead after
# a reboot, and it rolls the host back: a weeks-old config/ and data/
# (gateway.db included) copied over live state, by a process nobody asked for.
#
# Driven on the ok path AND the rollback path, because the removal is an EXIT
# trap and a check on only one of them would not notice a trap that had become
# a call before a single `exit`. Darwin only: Linux's guard is a
# `systemd-run --collect` transient unit, which systemd reaps itself.
# ---------------------------------------------------------------------------
t_guard_removes_its_own_plist() {
    _behaviour="$1"; _want_phase="$2"
    _r="$(mktemp -d)"; setup_fake_host "$_r" Darwin; fake_supervisor "$_r" Darwin "$_behaviour"
    _t="$(make_txn "$_r" Darwin)"
    write_fake_bin "$_r/bin/burrowee-gateway" "NEW BINARY v0.3.1" v0.3.1
    printf '<plist/>\n' > "$_r/units/com.burrowee.gateway.guard.plist"
    printf 'handoff\n' > "$_t/phase"
    run_guard "$_r" "$_t" Darwin

    [ "$(cat "$_t/phase")" = "$_want_phase" ] \
        || fail "plist-removal[$_behaviour]: phase = $(cat "$_t/phase"), want $_want_phase"
    [ ! -e "$_r/units/com.burrowee.gateway.guard.plist" ] \
        || fail "plist-removal[$_behaviour]: the guard left its own RunAtLoad plist behind — launchd re-runs it against this transaction at every boot"
    rm -rf "$_r"
}

# Retention keeps this transaction and the two before it — platform-agnostic

# (rm -rf and lexical sort, no supervisor call involved), so this runs once
# rather than per platform, same discipline as the static checks below.
t_guard_ok_prunes_old_transactions() {
    _r="$(mktemp -d)"; setup_fake_host "$_r" Linux; fake_supervisor "$_r" Linux advance
    _install="$_r/var/gateway/install"
    for _stamp in 20260101T000000Z 20260102T000000Z 20260103T000000Z 20260104T000000Z; do
        mkdir -p "$_install/$_stamp"
        printf 'stale\n' > "$_install/$_stamp/marker"
    done
    _t="$(make_txn "$_r" Linux)"
    write_fake_bin "$_r/bin/burrowee-gateway" "NEW BINARY v0.3.1" v0.3.1
    printf 'handoff\n' > "$_t/phase"
    run_guard "$_r" "$_t" Linux

    [ "$(cat "$_t/phase")" = ok ] || fail "prune-fixture: phase = $(cat "$_t/phase"), want ok"
    [ -d "$_t" ] || fail "retention deleted the transaction currently in flight"
    [ -d "$_install/20260104T000000Z" ] || fail "retention deleted a transaction that should have been kept"
    [ -d "$_install/20260103T000000Z" ] || fail "retention deleted a transaction that should have been kept"
    [ -d "$_install/20260102T000000Z" ] && fail "retention kept a transaction older than the last two plus the current one"
    [ -d "$_install/20260101T000000Z" ] && fail "retention kept a transaction older than the last two plus the current one"

    # THE EXIT CONTRACT, and this is the assertion the finding is about. The
    # prune body used to end each iteration with
    # `[ "$_i" -le "$_drop" ] && [ -n "$_old" ] && rm -rf …`. On the LAST
    # iteration the counter guard is false, so the AND-list returns 1 — and an
    # AND-list is not exempt from `set -e` when it is the final stage of a
    # PIPELINE, which the `while` is. The guard died right there, after
    # `phase ok` had already been written and BEFORE do_restart's `exit 0`, so
    # it left with status 1: "rolled-back" by its own contract, on a host it
    # had just verified serving the new build. Everything above still passed
    # (the prune itself happened, the phase was already ok), which is why this
    # went unseen — the status is the only witness.
    [ "$GUARD_RC" = 0 ] \
        || fail "the guard exited $GUARD_RC after pruning, want 0 — phase says ok but the exit contract says $([ "$GUARD_RC" = 1 ] && echo rolled-back || echo failed); guard.log:
$(cat "$_t/guard.log" 2>/dev/null)"
    grep -q 'snapshot retention applied' "$_t/guard.log" 2>/dev/null \
        || fail "apply_retention never logged its result — it died inside the prune loop"
    rm -rf "$_r"
}

# The ok path with NOTHING to prune must still exit 0 — the control for the
# check above, so a "fix" that simply stopped pruning would be visible rather
# than green.
t_guard_ok_exits_zero() {
    _plat="$1"
    _r="$(mktemp -d)"; setup_fake_host "$_r" "$_plat"; fake_supervisor "$_r" "$_plat" advance
    _t="$(make_txn "$_r" "$_plat")"
    write_fake_bin "$_r/bin/burrowee-gateway" "NEW BINARY v0.3.1" v0.3.1
    printf 'handoff\n' > "$_t/phase"
    run_guard "$_r" "$_t" "$_plat"
    [ "$GUARD_RC" = 0 ] || fail "[$_plat] a verified restart exited $GUARD_RC, want 0"
    rm -rf "$_r"
}

# ---------------------------------------------------------------------------
# C2 — THE FOREGROUND ABORT PATHS MUST END WITH A SERVING DAEMON.
#
# A declined consent prompt and a failed Phase 2 check used to do
# `snapshot_restore; txn_phase rolled-back; exit 1` in the installer's own
# foreground. snapshot_restore only COPIES FILES; `rolled-back` is terminal, so
# the guard's watch loop took its "already terminal" arm and exited without
# doing anything. On a MIGRATING host that is the reported stranding through a
# different door: migrate_from_legacy runs ~150 lines before the consent
# prompt, and adopt_user_tree.sh boots the serve label out of both domains to
# copy state at rest, so from there until the guard's restart the gateway is
# DOWN and, on Darwin, UNLOADED.
#
# The fixture below is that host: the daemon is stopped (running.json is the
# STALE file the dead daemon left behind — it is never removed on stop, which
# is exactly why the guard cannot use the version alone as a liveness test),
# the installer dies at a non-terminal phase without handing off, and the guard
# must restore AND restart AND verify.
# ---------------------------------------------------------------------------
t_abort_hands_the_undo_to_the_guard() {
    _plat="$1"
    _r="$(mktemp -d)"; setup_fake_host "$_r" "$_plat"
    _t="$(make_txn "$_r" "$_plat")"

    # Mid-install: the new build is on disk and the migration has stopped the
    # daemon. running.json still names the OLD version, with a pid that is
    # gone — the trap a version-only liveness check falls into.
    write_fake_bin "$_r/bin/burrowee-gateway" "NEW BINARY v0.3.1" v0.3.1
    printf '{"version":"v0.2.13","pid":999999,"started_at":0}\n' > "$_r/var/gateway/running.json"
    fake_supervisor "$_r" "$_plat" advance
    printf 'v0.2.13\n' > "$_r/newver"   # a restart brings the RESTORED build back

    # The installer aborts (declined consent / failed verify) — it prints and
    # exits, leaving the phase non-terminal and never restoring anything.
    sh -c 'sleep 30' &
    _ipid=$!
    printf '%s\n' "$_ipid" > "$_t/installer.pid"
    printf 'verified\n' > "$_t/phase"

    (sleep 1; kill -9 "$_ipid" 2>/dev/null || true) &
    run_guard "$_r" "$_t" "$_plat" 30
    wait "$_ipid" 2>/dev/null || true

    [ "$(cat "$_t/phase")" = rolled-back ] \
        || fail "[$_plat] an aborted install left phase = $(cat "$_t/phase"), want rolled-back"
    grep -q 'OLD BINARY' "$_r/bin/burrowee-gateway" \
        || fail "[$_plat] the abort did not restore the previous binary"
    grep -q "$(restart_verb "$_plat")" "$(supervisor_calls "$_r" "$_plat")" \
        || fail "[$_plat] the abort restored files but never restarted the daemon — the host is left DOWN, which is the whole finding; guard.log:
$(cat "$_t/guard.log" 2>/dev/null)"
    grep -q '"version":"v0.2.13"' "$_r/var/gateway/running.json" \
        || fail "[$_plat] the daemon never came back up after the abort"
    rm -rf "$_r"
}

# The other half of C2's judgement call: on a host whose daemon was NEVER
# stopped — an operator declining the prompt on a plain reinstall — the guard
# restores the files and does NOT bounce the service. Declining is precisely a
# request not to drop this connection, and a rollback that restarts anyway
# drops it.
#
# The discriminator is liveness, not version: running.json's pid must name a
# process that is actually alive. This fixture gives it one (a real sleep in
# this shell), which the stranded-host case above deliberately does not.
t_abort_does_not_bounce_a_live_daemon() {
    _plat="$1"
    _r="$(mktemp -d)"; setup_fake_host "$_r" "$_plat"
    _t="$(make_txn "$_r" "$_plat")"
    write_fake_bin "$_r/bin/burrowee-gateway" "NEW BINARY v0.3.1" v0.3.1
    fake_supervisor "$_r" "$_plat" advance

    # A genuinely live "daemon", recorded in running.json the way core's
    # runtime_version.WriteRunning records it.
    sh -c 'sleep 30' &
    _dpid=$!
    printf '{"version":"v0.2.13","pid":%s,"started_at":0}\n' "$_dpid" > "$_r/var/gateway/running.json"

    sh -c 'sleep 30' &
    _ipid=$!
    printf '%s\n' "$_ipid" > "$_t/installer.pid"
    printf 'verified\n' > "$_t/phase"

    (sleep 1; kill -9 "$_ipid" 2>/dev/null || true) &
    run_guard "$_r" "$_t" "$_plat" 30
    wait "$_ipid" 2>/dev/null || true

    [ "$(cat "$_t/phase")" = rolled-back ] \
        || fail "[$_plat] phase = $(cat "$_t/phase"), want rolled-back"
    grep -q 'OLD BINARY' "$_r/bin/burrowee-gateway" \
        || fail "[$_plat] the undisturbed abort did not restore the previous binary"
    ! grep -q "$(restart_verb "$_plat")" "$(supervisor_calls "$_r" "$_plat")" \
        || fail "[$_plat] the guard bounced a daemon that was still serving — declining the prompt is a request NOT to drop this connection; calls:
$(cat "$(supervisor_calls "$_r" "$_plat")")"

    kill "$_dpid" 2>/dev/null || true
    wait "$_dpid" 2>/dev/null || true
    rm -rf "$_r"
}

# ---------------------------------------------------------------------------
# I8 — a CHANGED unit body is re-read; an unchanged one is not.
#
# `bootstrap` on an already-loaded label exits 5 and does nothing, and
# `kickstart -k` restarts the job launchd holds IN MEMORY: neither re-reads the
# plist. With the installer's bootout gone, a rendered change to ExecStart,
# KeepAlive or StandardOutPath therefore took effect only at the next reboot —
# "files converged, process still stale". The guard is the safe place to do the
# bootout (it is detached; the stranding was a bootout whose bootstrap sat in a
# killable session), gated on place_unit having recorded that the file actually
# changed.
#
# Darwin only: Linux's `daemon-reload` + `restart` re-reads the unit by
# construction, so there is nothing to gate there — which the unchanged-case
# assertion below also proves, by running on both platforms.
# ---------------------------------------------------------------------------
t_guard_reloads_a_changed_unit_body() {
    _r="$(mktemp -d)"; setup_fake_host "$_r" Darwin; fake_supervisor "$_r" Darwin advance
    _t="$(make_txn "$_r" Darwin)"
    write_fake_bin "$_r/bin/burrowee-gateway" "NEW BINARY v0.3.1" v0.3.1
    printf 'com.burrowee.gateway.plist\n' > "$_t/units-changed"
    printf 'handoff\n' > "$_t/phase"
    run_guard "$_r" "$_t" Darwin

    _calls="$(supervisor_calls "$_r" Darwin)"
    [ "$(cat "$_t/phase")" = ok ] || fail "changed-unit: phase = $(cat "$_t/phase"), want ok"
    grep -q 'bootout system/com.burrowee.gateway$' "$_calls" \
        || fail "the guard did not boot the serve label out for a CHANGED plist — launchd never re-reads it, so the rendered change takes effect only at the next reboot; calls:
$(cat "$_calls")"
    grep -q 'kickstart -k system/com.burrowee.gateway$' "$_calls" \
        || fail "the guard booted the label out without restarting it"
    rm -rf "$_r"
}

t_guard_does_not_reload_an_unchanged_unit_body() {
    _plat="$1"
    _r="$(mktemp -d)"; setup_fake_host "$_r" "$_plat"; fake_supervisor "$_r" "$_plat" advance
    _t="$(make_txn "$_r" "$_plat")"
    write_fake_bin "$_r/bin/burrowee-gateway" "NEW BINARY v0.3.1" v0.3.1
    # Only the UPDATER's unit changed — the serve unit did not.
    printf '%s\n' "$(updater_unit_name "$_plat")" > "$_t/units-changed"
    printf 'handoff\n' > "$_t/phase"
    run_guard "$_r" "$_t" "$_plat"

    _calls="$(supervisor_calls "$_r" "$_plat")"
    [ "$(cat "$_t/phase")" = ok ] || fail "[$_plat] unchanged-unit: phase = $(cat "$_t/phase"), want ok"
    ! grep -q "$(unsupervise_pattern "$_plat" "$(serve_unit_name "$_plat")")" "$_calls" \
        || fail "[$_plat] the guard unsupervised the serve label although its unit file did not change; calls:
$(cat "$_calls")"
    rm -rf "$_r"
}

# ---------------------------------------------------------------------------
# I13 — a rollback on a host with no recorded running version must not report
# `failed`.
#
# snapshot_take writes running_version=unknown when running.json is absent (a
# fresh host, or one whose daemon was already down when the install began).
# "unknown" is non-empty, so verify_serving compared against the literal string
# `unknown`, burned the whole 60s ceiling, failed, and the guard ended at phase
# `failed` — "this host needs hands" — on a rollback that may have completed
# perfectly.
# ---------------------------------------------------------------------------
t_rollback_with_no_recorded_version_is_not_a_failure() {
    _plat="$1"
    _r="$(mktemp -d)"; setup_fake_host "$_r" "$_plat"; fake_supervisor "$_r" "$_plat" dead
    _t="$(make_txn "$_r" "$_plat")"
    printf 'stamp=20260831T140211Z\nrunning_version=unknown\nconsistency=exact\n' > "$_t/manifest"
    rm -f "$_r/var/gateway/running.json"
    write_fake_bin "$_r/bin/burrowee-gateway" "NEW BINARY v0.3.1" v0.3.1
    printf 'handoff\n' > "$_t/phase"

    run_guard "$_r" "$_t" "$_plat"

    [ "$(cat "$_t/phase")" = rolled-back ] \
        || fail "[$_plat] phase = $(cat "$_t/phase"), want rolled-back — 'unknown' is a placeholder, not a version to verify against"
    [ "$GUARD_RC" = 1 ] || fail "[$_plat] guard exited $GUARD_RC, want 1 (rolled-back)"
    grep -q 'recorded no running version' "$_t/guard.log" 2>/dev/null \
        || fail "[$_plat] guard.log does not say the restore could not be verified: $(cat "$_t/guard.log" 2>/dev/null)"
    # And it never waited for a daemon to report the literal string "unknown".
    # That is the precise symptom: verify_serving logs "daemon did not report
    # <want>" with the string it compared, so the placeholder appearing there
    # is proof it was treated as a version. Checked by CONTENT rather than by
    # elapsed time — do_restart's own verify against the new build legitimately
    # burns the ceiling first on this fixture, so a stopwatch here would be
    # measuring the wrong wait.
    grep -q 'did not report unknown' "$_t/guard.log" 2>/dev/null \
        && fail "[$_plat] the guard waited for the daemon to report the literal string 'unknown'"
    rm -rf "$_r"

}

# ---------------------------------------------------------------------------
# I10 — the deadline measures a WEDGE, not an operator standing at a prompt.
#
# The 900s clock starts at Phase 0 and spans both blocking reads (the setup
# blob/PIN prompt and the consent prompt). An operator who steps away at
# `blob>` got the guard rolling back underneath a live installer, which then
# wrote phase=handoff to a guard that had already exited: nothing restarted,
# reattach timed out, and the install reported success over a partially undone
# host. install.sh now refreshes $TXN/heartbeat across each blocking prompt and
# the guard measures its deadline from the later of "armed" and that stamp.
# ---------------------------------------------------------------------------
t_heartbeat_defers_the_deadline() {
    _plat=Linux
    _deadline=4
    _r="$(mktemp -d)"; setup_fake_host "$_r" "$_plat"; fake_supervisor "$_r" "$_plat" dead
    _t="$(make_txn "$_r" "$_plat")"
    write_fake_bin "$_r/bin/burrowee-gateway" "NEW BINARY v0.3.1" v0.3.1
    printf 'replacing\n' > "$_t/phase"

    sh -c 'sleep 30' &
    _ipid=$!
    printf '%s\n' "$_ipid" > "$_t/installer.pid"

    # A ticker standing in for install.sh's own heartbeat_start, refreshing
    # while the (simulated) operator reads the prompt.
    ( _n=0; while [ "$_n" -lt 12 ]; do date -u +%s > "$_t/heartbeat"; sleep 1; _n=$((_n + 1)); done ) &
    _hb=$!

    GUARD_LAUNCHCTL="$_r/launchctl" GUARD_SYSTEMCTL="$_r/systemctl" \
    GUARD_DEADLINE="$_deadline" GUARD_VERIFY_CEILING=2 GUARD_VERIFY_INTERVAL=1 \
    BURROWEE_BIN_DIR="$_r/bin" BURROWEE_LAUNCHD_DIR="$_r/units" \
    BURROWEE_SYSTEMD_DIR="$_r/units" \
    BURROWEE_SYSTEM_CONFIG_DIR="$_r/etc/gateway" \
    BURROWEE_SYSTEM_DATA_DIR="$_r/var/gateway" \
    GUARD_UNAME="$_plat" \
    sh "$GUARD" "$_t" >/dev/null 2>&1 &
    _gpid=$!

    # Well past a 4s deadline, but every second of it heartbeated.
    sleep 8
    _late="$(cat "$_t/phase")"

    kill "$_hb" 2>/dev/null || true; wait "$_hb" 2>/dev/null || true
    # The heartbeat has stopped; the deadline now runs from its last stamp.
    wait "$_gpid" 2>/dev/null || true
    kill "$_ipid" 2>/dev/null || true; wait "$_ipid" 2>/dev/null || true

    [ "$_late" = replacing ] \
        || fail "the guard rolled back at phase '$_late' 8s into a 4s deadline that was heartbeated the whole way — an operator standing at a prompt is not a wedge"
    [ "$(cat "$_t/phase")" = rolled-back ] \
        || fail "the deadline never fired after the heartbeat stopped: phase = $(cat "$_t/phase")"
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
    # Leading whitespace is tolerated on the handoff anchor (and only there):
    # `txn_phase handoff` now sits inside the `if [ "$GUARD_ARMED" = 1 ]` block
    # that honours BURROWEE_NO_RESTART. The claim is about order, not column,
    # and the anchor is still a whole line.
    _phase1="$(grep -n '^txn_phase replacing$' "$_f" | head -1 | cut -d: -f1)"
    _v="$(grep -n '^verify_placement || abort_install ' "$_f" | head -1 | cut -d: -f1)"
    _end="$(grep -n '^[[:space:]]*txn_phase handoff$' "$_f" | head -1 | cut -d: -f1)"

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
    _r="$(grep -n '^[[:space:]]*echo "    burrowee gateway service guard-status"$' "$_f" | head -1 | cut -d: -f1)"
    _h="$(grep -n '^[[:space:]]*txn_phase handoff$' "$_f" | head -1 | cut -d: -f1)"

    [ -n "$_r" ] || { fail "install.sh never prints the unconditional guard-status reconnect line ahead of the handoff"; return; }
    [ -n "$_h" ] || { fail "install.sh never reaches txn_phase handoff"; return; }
    [ "$_r" -lt "$_h" ] || fail "the reconnect line (line $_r) is printed after the handoff (line $_h)"
}

# A verification failure must abort rather than hand off — and it must abort
# THROUGH abort_install, not by restoring in the foreground.
#
# REWRITTEN, and the rewrite is the finding. The old shape was
# `snapshot_restore; txn_phase rolled-back; exit 1` inline, and this check
# asserted the branch existed. Both halves of that branch were wrong:
# snapshot_restore only COPIES FILES, and `rolled-back` is terminal, so the
# guard's watch loop took its "already terminal" arm and did nothing. On a host
# whose migration had already stopped (and on Darwin unloaded) the daemon —
# migrate_from_legacy runs ~150 lines earlier — a failed Phase 2 check left it
# down with the only process that could restart it told the job was finished.
# The undo now goes to the guard, whose rollback() restores AND restarts AND
# verifies. t_abort_hands_the_undo_to_the_guard below drives that end to end.
t_verify_failure_aborts_to_the_guard() {
    _f="$HERE/inner/gateway/install.sh"
    grep -q '^verify_placement || abort_install ' "$_f" \
        || fail "a failed verify_placement does not abort the install"
    grep -q '^verify_units     || abort_install ' "$_f" \
        || fail "a failed verify_units does not abort the install"
    # The foreground must not pre-empt the guard: neither Phase 2 branch, nor
    # the consent decline, may restore or mark the transaction terminal itself.
    # Comments are stripped — abort_install's own header explains at length why
    # it does not do those things, and an unstripped check would pass on that
    # prose alone with the guard-handoff deleted from the code.
    _body="$(sed -n '/^abort_install() {/,/^}/p' "$_f" | grep -v '^[[:space:]]*#')"
    printf '%s\n' "$_body" | grep -q 'GUARD_ARMED' \
        || fail "abort_install does not branch on whether a guard is watching"
    _armed="$(printf '%s\n' "$_body" | sed -n '/GUARD_ARMED. = 1 /,/^    fi$/p')"
    printf '%s\n' "$_armed" | grep -q 'snapshot_restore' \
        && fail "abort_install restores in the foreground even with a guard armed — snapshot_restore only copies files, it never restarts"
    printf '%s\n' "$_armed" | grep -q 'txn_phase' \
        && fail "abort_install marks the transaction terminal with a guard armed — the guard then takes its 'already terminal' branch and does nothing"
    _decline="$(sed -n '/^consent_to_sever() {/,/^}/p' "$_f" | grep -v '^[[:space:]]*#')"
    printf '%s\n' "$_decline" | grep -q 'snapshot_restore' \
        && fail "a declined consent still restores in the foreground"
    printf '%s\n' "$_decline" | grep -q 'txn_phase' \
        && fail "a declined consent still marks the transaction terminal"
    return 0
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
    t_guard_ok_exits_zero "$_plat"
    t_guard_rolls_back "$_plat"
    t_guard_ok_advances_updater "$_plat"
    t_guard_ok_sweeps_stale_bins "$_plat"
    t_guard_deadline_exceeded "$_plat"
    t_abort_hands_the_undo_to_the_guard "$_plat"
    t_abort_does_not_bounce_a_live_daemon "$_plat"
    t_guard_does_not_reload_an_unchanged_unit_body "$_plat"
    t_rollback_with_no_recorded_version_is_not_a_failure "$_plat"

    t_verify_units_passes "$_plat"
    t_verify_units_fails_when_unit_missing "$_plat"
    t_verify_units_fails_when_exec_target_not_executable "$_plat"
done

t_guard_ok_prunes_old_transactions
t_guard_removes_its_own_plist advance ok
t_guard_removes_its_own_plist dead rolled-back
t_guard_reloads_a_changed_unit_body

t_heartbeat_defers_the_deadline
t_verify_precedes_handoff

t_consent_is_tty_gated
t_reconnect_line_precedes_handoff
t_verify_failure_aborts_to_the_guard

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
printf 'ok: guard reaches ok / rolled-back / deadline correctly, post-success work runs, and Phase 2 verification catches a bad placement (Darwin + Linux)\n'

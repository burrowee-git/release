#!/bin/sh
# tools/guard-rollback.test.sh — drives inner/gateway/guard.sh against a fake
# supervisor and a fake host tree. Nothing here touches a real launchd,
# systemd, binary or database.
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

for _plat in Darwin Linux; do
    t_guard_ok "$_plat"
    t_guard_rolls_back "$_plat"
done

if [ "$fails" -ne 0 ]; then
    printf '%s: %d check(s) failed\n' "$0" "$fails" >&2
    exit 1
fi
printf 'ok: guard reaches ok and rolled-back correctly (Darwin + Linux)\n'

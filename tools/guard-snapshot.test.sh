#!/bin/sh
# tools/guard-snapshot.test.sh — snapshot_take captures the last working point,
# and snapshot_restore puts it back.
#
#     sh tools/guard-snapshot.test.sh
#     dash tools/guard-snapshot.test.sh
set -eu

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
fails=0
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }

# serve_unit_name <platform> — the serve unit's filename on <platform>, the
# same name both snapshot_take and snapshot_restore branch on via uname -s.
serve_unit_name() {
    case "$1" in
    Darwin) echo com.burrowee.gateway.plist ;;
    Linux)  echo burrowee-gateway.service ;;
    esac
}

# setup_fake_host <root> <platform> — a host tree with an old install in
# place, including whichever unit shape <platform> ships: a single launchd
# .plist for Darwin, both systemd .service units for Linux. Every file uses
# an OLD-prefixed marker body (matching OLD BINARY / OLD KEY below) so a
# restore assertion is just "does this marker come back", regardless of which
# platform's filename it landed under.
setup_fake_host() {
    _r="$1"; _plat="$2"
    mkdir -p "$_r/bin" "$_r/etc/gateway/identity" "$_r/var/gateway" "$_r/units"
    for b in burrowee burrowee-gateway burrowee-gateway-cli \
             burrowee-gateway-console burrowee-register burrowee-gateway-updater; do
        printf 'OLD BINARY\n' > "$_r/bin/$b"; chmod 755 "$_r/bin/$b"
    done
    printf 'OLD KEY\n'   > "$_r/etc/gateway/identity/relay_ed.key"
    printf 'OLD DB\n'    > "$_r/var/gateway/gateway.db"
    printf 'OLD STATE\n' > "$_r/var/gateway/state.txt"
    case "$_plat" in
    Darwin)
        printf 'OLD UNIT\n' > "$_r/units/com.burrowee.gateway.plist"
        ;;
    Linux)
        printf 'OLD UNIT\n' > "$_r/units/burrowee-gateway.service"
        printf 'OLD UNIT\n' > "$_r/units/burrowee-gateway-updater.service"
        ;;
    esac
    printf '{"version":"v0.2.13","pid":1,"started_at":0}\n' > "$_r/var/gateway/running.json"
}

# make_sudo_stub <dir> — a pass-through `sudo`, same shape as
# inner/gateway/install_test's writeSudoStub: strip a leading -n, exec the
# rest. install.sh's run_root always tries to elevate, but the fake host tree
# here is a tmpdir this test process already owns, and a non-interactive shell
# suite has no tty and no cached sudo credential to elevate with for real —
# burrowee-ci's own account requires an interactive password. The stub makes
# every run_root call a same-user exec instead of a real privilege change:
# the SAME branch run_root takes on a real tty-less, no-cached-credential
# host (sudo -n), just with a faked outcome rather than a faked decision.
make_sudo_stub() {
    mkdir -p "$1"
    cat > "$1/sudo" <<'STUB'
#!/bin/sh
[ "$1" = "-n" ] && shift
exec "$@"
STUB
    chmod 755 "$1/sudo"
}

# make_uname_stub <dir> <platform> — pins `uname -s` to <platform>, same shape
# as inner/gateway/install_test's stubUname. snapshot_take and
# snapshot_restore both branch on uname -s (Darwin's launchd units vs Linux's
# systemd units), and BOTH branches ship to production hosts — Burrowee
# gateways run on Linux — so the suite drives each one explicitly rather than
# trusting whatever OS happens to run the test (this suite runs on
# burrowee-ci, which is Linux; the Darwin branch would otherwise go untested).
make_uname_stub() {
    mkdir -p "$1"
    _plat="$2"
    cat > "$1/uname" <<STUB
#!/bin/sh
if [ "\$1" = "-s" ]; then echo $_plat; else /usr/bin/uname "\$@"; fi
STUB
    chmod 755 "$1/uname"
}

# run_installer_fn <root> <platform> <shell-snippet> — source install.sh with
# its side effects suppressed (BURROWEE_SOURCE_ONLY short-circuits the mode
# dispatch), uname pinned to <platform>, pointed at the fake host, then run
# the snippet against its functions. Both unit-dir env vars point at the same
# fixture directory — only one is ever read, per the uname stub.
run_installer_fn() {
    _r="$1"; _plat="$2"; _snippet="$3"
    _stub="$_r/.stub"
    make_sudo_stub "$_stub"
    make_uname_stub "$_stub" "$_plat"
    BURROWEE_SOURCE_ONLY=1 \
    PATH="$_stub:$PATH" \
    BURROWEE_BIN_DIR="$_r/bin" \
    BURROWEE_LAUNCHD_DIR="$_r/units" \
    BURROWEE_SYSTEMD_DIR="$_r/units" \
    BURROWEE_SYSTEM_CONFIG_DIR="$_r/etc/gateway" \
    BURROWEE_SYSTEM_DATA_DIR="$_r/var/gateway" \
    sh -c ". '$HERE/inner/gateway/install.sh'; $_snippet"
}

# snapshot_take must capture every binary, the platform's own unit(s), and
# both trees, and record a manifest naming the version it snapshotted. Run
# once per platform shape (see the loop at the bottom) — do not copy-paste
# this body per platform.
t_snapshot_captures_everything() {
    _plat="$1"
    _unit="$(serve_unit_name "$_plat")"
    _root="$(mktemp -d)"
    setup_fake_host "$_root" "$_plat"
    run_installer_fn "$_root" "$_plat" 'txn_begin; snapshot_take'

    _txn="$(ls -d "$_root/var/gateway/install"/*/ | head -1)"
    for b in burrowee burrowee-gateway burrowee-gateway-cli; do
        [ -f "$_txn/snapshot/bin/$b" ] || fail "[$_plat] snapshot missing bin/$b"
    done
    [ -f "$_txn/snapshot/units/$_unit" ]                      || fail "[$_plat] snapshot missing the serve unit"
    [ -f "$_txn/snapshot/config/identity/relay_ed.key" ]      || fail "[$_plat] snapshot missing the identity key"
    [ -f "$_txn/snapshot/data/gateway.db" ]                   || fail "[$_plat] snapshot missing gateway.db"
    [ -f "$_txn/snapshot/data/state.txt" ]                    || fail "[$_plat] snapshot missing the state tree"
    grep -q '^running_version=' "$_txn/manifest" || fail "[$_plat] manifest records no running_version"
    grep -q '^consistency='     "$_txn/manifest" || fail "[$_plat] manifest records no consistency"
    # The transaction tree must NOT snapshot itself.
    [ ! -d "$_txn/snapshot/data/install" ] || fail "[$_plat] snapshot recursed into install/"
    rm -rf "$_root"
}

# snapshot_restore must put every one of them back, byte for byte — binary,
# unit file, identity key AND the general state tree, on both platform
# shapes. Run once per platform shape (see the loop at the bottom).
t_snapshot_restores_everything() {
    _plat="$1"
    _unit="$(serve_unit_name "$_plat")"
    _root="$(mktemp -d)"
    setup_fake_host "$_root" "$_plat"
    run_installer_fn "$_root" "$_plat" 'txn_begin; snapshot_take'
    _txn="$(ls -d "$_root/var/gateway/install"/*/ | head -1)"

    printf 'NEW BINARY\n' > "$_root/bin/burrowee-gateway"
    printf 'NEW KEY\n'    > "$_root/etc/gateway/identity/relay_ed.key"
    printf 'NEW UNIT\n'   > "$_root/units/$_unit"
    printf 'NEW STATE\n'  > "$_root/var/gateway/state.txt"
    run_installer_fn "$_root" "$_plat" "TXN_DIR='${_txn%/}'; snapshot_restore"

    grep -q 'OLD BINARY' "$_root/bin/burrowee-gateway" \
        || fail "[$_plat] snapshot_restore did not restore the binary"
    grep -q 'OLD KEY' "$_root/etc/gateway/identity/relay_ed.key" \
        || fail "[$_plat] snapshot_restore did not restore the identity key"
    grep -q 'OLD UNIT' "$_root/units/$_unit" \
        || fail "[$_plat] snapshot_restore did not restore the unit file"
    grep -q 'OLD STATE' "$_root/var/gateway/state.txt" \
        || fail "[$_plat] snapshot_restore did not restore the state tree"
    rm -rf "$_root"
}

# ---------------------------------------------------------------------------
# consistency=no-database — a run that captured no database must not claim an
# exact copy of one.
#
# SNAPSHOT_CONSISTENCY is initialised to `exact` and snapshot_db early-returns
# on a host with no gateway.db, so the manifest recorded `exact` for a snapshot
# that contains no database at all — and `guard-status` prints that field
# through to the operator verbatim (gateway's guard_status.go reads
# txn.Manifest["consistency"] and formats it as free text; it is a manifest
# field, not a phase, so a third value needs nothing changed in that repo).
#
# The value is a claim about what the snapshot HOLDS, which is what decides
# whether a rollback can put the store back. "exact" on an empty snapshot is
# the one reading that would send an operator looking for a database that was
# never captured.
# ---------------------------------------------------------------------------
t_snapshot_records_no_database_when_there_is_none() {
    _plat="$1"
    _root="$(mktemp -d)"
    setup_fake_host "$_root" "$_plat"
    rm -f "$_root/var/gateway/gateway.db"
    run_installer_fn "$_root" "$_plat" 'txn_begin; snapshot_take'

    _txn="$(ls -d "$_root/var/gateway/install"/*/ | head -1)"
    grep -q '^consistency=no-database$' "$_txn/manifest" \
        || fail "[$_plat] manifest records '$(sed -n 's/^consistency=//p' "$_txn/manifest")' on a host with no gateway.db, want no-database — 'exact' claims a faithful copy of a database that was never there"
    [ ! -f "$_txn/snapshot/data/gateway.db" ] \
        || fail "[$_plat] a database appeared in the snapshot of a host that has none"
    rm -rf "$_root"
}

# The control: a host that DOES have a database must never record
# no-database. Which of the two real values it lands on (exact via the cli's
# own `db snapshot` or sqlite3's .backup, best-effort via the three-file copy)
# depends on what this box has installed, and both are honest — only the
# no-database claim would be a lie here.
t_snapshot_does_not_record_no_database_when_there_is_one() {
    _plat="$1"
    _root="$(mktemp -d)"
    setup_fake_host "$_root" "$_plat"
    run_installer_fn "$_root" "$_plat" 'txn_begin; snapshot_take'

    _txn="$(ls -d "$_root/var/gateway/install"/*/ | head -1)"
    grep -q '^consistency=no-database$' "$_txn/manifest" \
        && fail "[$_plat] manifest records no-database on a host whose gateway.db was snapshotted"
    grep -qE '^consistency=(exact|best-effort)$' "$_txn/manifest" \
        || fail "[$_plat] manifest records an unrecognised consistency: $(sed -n 's/^consistency=//p' "$_txn/manifest")"
    rm -rf "$_root"
}

for _plat in Darwin Linux; do
    t_snapshot_captures_everything "$_plat"
    t_snapshot_restores_everything "$_plat"
    t_snapshot_records_no_database_when_there_is_none "$_plat"
    t_snapshot_does_not_record_no_database_when_there_is_one "$_plat"
done

if [ "$fails" -ne 0 ]; then
    printf '%s: %d check(s) failed\n' "$0" "$fails" >&2
    exit 1
fi
printf 'ok: snapshot_take + snapshot_restore (Darwin + Linux)\n'

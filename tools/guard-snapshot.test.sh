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

# setup_fake_host <root> — a host tree with an old install in place.
setup_fake_host() {
    _r="$1"
    mkdir -p "$_r/bin" "$_r/etc/gateway/identity" "$_r/var/gateway" "$_r/units"
    for b in burrowee burrowee-gateway burrowee-gateway-cli \
             burrowee-gateway-console burrowee-register burrowee-gateway-updater; do
        printf 'OLD BINARY\n' > "$_r/bin/$b"; chmod 755 "$_r/bin/$b"
    done
    printf 'OLD KEY\n'  > "$_r/etc/gateway/identity/relay_ed.key"
    printf 'OLD DB\n'   > "$_r/var/gateway/gateway.db"
    printf '<plist/>\n' > "$_r/units/com.burrowee.gateway.plist"
    printf '{"version":"v0.2.13","pid":1,"started_at":0}\n' > "$_r/var/gateway/running.json"
}

# make_sudo_stub <dir> — a pass-through `sudo`, same shape as
# inner/gateway/install_test's writeSudoStub: strip a leading -n, exec the
# rest. install.sh's run_root always tries to elevate, but the fake host tree
# here is a tmpdir this test process already owns, and a non-interactive shell
# suite has no tty and no cached sudo credential to elevate with for real —
# burrowee-ci's own account requires an interactive password. The stub makes
# every run_root call a same-user exec instead of a real privilege change.
make_sudo_stub() {
    mkdir -p "$1"
    cat > "$1/sudo" <<'STUB'
#!/bin/sh
[ "$1" = "-n" ] && shift
exec "$@"
STUB
    chmod 755 "$1/sudo"
}

# make_uname_stub <dir> — pins `uname -s` to Darwin, same shape as
# inner/gateway/install_test's stubUname. The fixture below is Darwin-shaped
# (a single .plist unit under BURROWEE_LAUNCHD_DIR, the launchd naming) so the
# snapshot/restore paths under test must be the launchd ones regardless of
# which OS actually runs this suite — this suite runs on burrowee-ci, which is
# Linux, and snapshot_take's own case statement branches on uname.
make_uname_stub() {
    mkdir -p "$1"
    cat > "$1/uname" <<'STUB'
#!/bin/sh
if [ "$1" = "-s" ]; then echo Darwin; else /usr/bin/uname "$@"; fi
STUB
    chmod 755 "$1/uname"
}

# run_installer_fn <root> <shell-snippet> — source install.sh with its side
# effects suppressed (BURROWEE_SOURCE_ONLY short-circuits the mode dispatch),
# pointed at the fake host, then run the snippet against its functions.
run_installer_fn() {
    _r="$1"; _snippet="$2"
    _stub="$_r/.stub"
    make_sudo_stub "$_stub"
    make_uname_stub "$_stub"
    BURROWEE_SOURCE_ONLY=1 \
    PATH="$_stub:$PATH" \
    BURROWEE_BIN_DIR="$_r/bin" \
    BURROWEE_LAUNCHD_DIR="$_r/units" \
    BURROWEE_SYSTEM_CONFIG_DIR="$_r/etc/gateway" \
    BURROWEE_SYSTEM_DATA_DIR="$_r/var/gateway" \
    sh -c ". '$HERE/inner/gateway/install.sh'; $_snippet"
}

# snapshot_take must capture every binary, both units, and both trees, and
# record a manifest naming the version it snapshotted.
t_snapshot_captures_everything() {
    _root="$(mktemp -d)"
    setup_fake_host "$_root"
    run_installer_fn "$_root" 'txn_begin; snapshot_take'

    _txn="$(ls -d "$_root/var/gateway/install"/*/ | head -1)"
    for b in burrowee burrowee-gateway burrowee-gateway-cli; do
        [ -f "$_txn/snapshot/bin/$b" ] || fail "snapshot missing bin/$b"
    done
    [ -f "$_txn/snapshot/units/com.burrowee.gateway.plist" ] || fail "snapshot missing the serve unit"
    [ -f "$_txn/snapshot/config/identity/relay_ed.key" ]     || fail "snapshot missing the identity key"
    [ -f "$_txn/snapshot/data/gateway.db" ]                  || fail "snapshot missing gateway.db"
    grep -q '^running_version=' "$_txn/manifest" || fail "manifest records no running_version"
    grep -q '^consistency='     "$_txn/manifest" || fail "manifest records no consistency"
    # The transaction tree must NOT snapshot itself.
    [ ! -d "$_txn/snapshot/data/install" ] || fail "snapshot recursed into install/"
    rm -rf "$_root"
}

# snapshot_restore must put every one of them back, byte for byte.
t_snapshot_restores_everything() {
    _root="$(mktemp -d)"
    setup_fake_host "$_root"
    run_installer_fn "$_root" 'txn_begin; snapshot_take'
    _txn="$(ls -d "$_root/var/gateway/install"/*/ | head -1)"

    printf 'NEW BINARY\n' > "$_root/bin/burrowee-gateway"
    printf 'NEW KEY\n'    > "$_root/etc/gateway/identity/relay_ed.key"
    run_installer_fn "$_root" "TXN_DIR='${_txn%/}'; snapshot_restore"

    grep -q 'OLD BINARY' "$_root/bin/burrowee-gateway" \
        || fail "snapshot_restore did not restore the binary"
    grep -q 'OLD KEY' "$_root/etc/gateway/identity/relay_ed.key" \
        || fail "snapshot_restore did not restore the identity key"
    rm -rf "$_root"
}

t_snapshot_captures_everything
t_snapshot_restores_everything

if [ "$fails" -ne 0 ]; then
    printf '%s: %d check(s) failed\n' "$0" "$fails" >&2
    exit 1
fi
printf 'ok: snapshot_take + snapshot_restore\n'

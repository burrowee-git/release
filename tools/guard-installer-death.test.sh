#!/bin/sh
# tools/guard-installer-death.test.sh — the regression test.
#
# THE BUG. Installing a gateway from a session tunnelled through that gateway
# stranded the host: load_units booted the daemon out, the tunnel died, the
# shell took SIGHUP before the bootstrap that would have brought it back, and
# the job was left UNLOADED — supervised by nothing, with the only route in
# gone. Observed on a live host 2026-08-31 installing
# v0.3.1.beta.2026.08.31.62a6f215.
#
# THE ASSERTION. Kill the installer at the phase the migration would have
# severed it, and the guard must still land the host on a serving daemon.
set -eu

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
GUARD="$HERE/inner/gateway/guard.sh"
fails=0
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }

R="$(mktemp -d)"
trap 'rm -rf "$R"' EXIT INT TERM HUP

mkdir -p "$R/bin" "$R/etc/gateway/identity" "$R/var/gateway" "$R/units"
for b in burrowee burrowee-gateway burrowee-gateway-cli \
         burrowee-gateway-console burrowee-register burrowee-gateway-updater; do
    printf 'OLD BINARY\n' > "$R/bin/$b"; chmod 755 "$R/bin/$b"
done
printf 'OLD KEY\n' > "$R/etc/gateway/identity/relay_ed.key"
printf '<plist/>\n' > "$R/units/com.burrowee.gateway.plist"
printf '{"version":"v0.2.13","pid":1,"started_at":0}\n' > "$R/var/gateway/running.json"

T="$R/var/gateway/install/20260831T140211Z"
mkdir -p "$T/snapshot/bin" "$T/snapshot/units" "$T/snapshot/config" "$T/snapshot/data"
cp "$R"/bin/* "$T/snapshot/bin/"
cp "$R/units/com.burrowee.gateway.plist" "$T/snapshot/units/"
cp -R "$R/etc/gateway/." "$T/snapshot/config/"
printf 'stamp=20260831T140211Z\nrunning_version=v0.2.13\nconsistency=exact\n' > "$T/manifest"

# A launchctl stub whose kickstart brings the SNAPSHOT's version back — the
# rollback path's expectation.
cat > "$R/launchctl" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$R/launchctl.calls"
case "\$1" in
  kickstart) printf '{"version":"v0.2.13","pid":9,"started_at":0}\n' > "$R/var/gateway/running.json" ;;
esac
exit 0
STUB
chmod 755 "$R/launchctl"
: > "$R/launchctl.calls"

# A stand-in installer that dies mid-Phase-1 — exactly what SIGHUP does when
# the migration's own stop severs the tunnel.
sh -c 'sleep 30' &
IPID=$!
printf '%s\n' "$IPID" > "$T/installer.pid"
printf 'replacing\n' > "$T/phase"

# The new build is already partly placed, as it would be at that moment.
printf 'NEW BINARY v0.3.1\n' > "$R/bin/burrowee-gateway"

GUARD_LAUNCHCTL="$R/launchctl" GUARD_UNAME=Darwin \
GUARD_DEADLINE=30 GUARD_VERIFY_CEILING=4 GUARD_VERIFY_INTERVAL=1 \
BURROWEE_BIN_DIR="$R/bin" BURROWEE_LAUNCHD_DIR="$R/units" \
BURROWEE_SYSTEM_CONFIG_DIR="$R/etc/gateway" BURROWEE_SYSTEM_DATA_DIR="$R/var/gateway" \
sh "$GUARD" "$T" >/dev/null 2>&1 &
GPID=$!

sleep 2
kill -9 "$IPID" 2>/dev/null || true   # the session dies
wait "$GPID" 2>/dev/null || true

PHASE="$(cat "$T/phase" 2>/dev/null || echo none)"
[ "$PHASE" = rolled-back ] || fail "phase = $PHASE, want rolled-back after the installer died"
grep -q 'OLD BINARY' "$R/bin/burrowee-gateway" \
    || fail "the old binary was not restored after the installer died"
grep -q 'kickstart' "$R/launchctl.calls" || fail "the guard never restarted the service"
! grep -q 'bootout system/com.burrowee.gateway$' "$R/launchctl.calls" \
    || fail "the guard booted the serve label out"

if [ "$fails" -ne 0 ]; then
    printf '%s: %d check(s) failed\n' "$0" "$fails" >&2
    exit 1
fi
printf 'ok: an installer killed mid-install leaves a serving daemon\n'

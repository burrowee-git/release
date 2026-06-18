#!/bin/sh
# Tests the edge inner installer's version-gated config migration in isolation.
# Sources install.sh with the source-only seam, points BIN_DIR at a stub
# burrowee-edge-cli, and drives migrate_config across version scenarios.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
INSTALLER="$ROOT/inner/edge/install.sh"
[ -f "$INSTALLER" ] || { echo "missing $INSTALLER" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
export PREFIX="$WORK/local"          # install.sh sets BIN_DIR="$PREFIX/bin"
BIN="$PREFIX/bin"
mkdir -p "$BIN" "$HOME"
CFG="$HOME/.burrowee/edge/config"

# Stub burrowee-edge-cli: only `config get|set`, file-backed (mirrors the real
# verbs — get exits non-zero when the key is absent; set upserts).
cat > "$BIN/burrowee-edge-cli" <<'STUB'
#!/bin/sh
CFG="$HOME/.burrowee/edge/config"
case "$1 $2" in
  "config get") [ -f "$CFG" ] && grep -q "^$3=" "$CFG" ;;
  "config set")
    mkdir -p "$(dirname "$CFG")"
    tmp="$CFG.t"; : > "$tmp"
    [ -f "$CFG" ] && grep -v "^$3=" "$CFG" >> "$tmp" 2>/dev/null
    printf '%s=%s\n' "$3" "$4" >> "$tmp"
    mv "$tmp" "$CFG" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/burrowee-edge-cli"

# Source the installer's functions (no install side-effects).
BURROWEE_INSTALLER_SOURCE_ONLY=1 . "$INSTALLER"

fail() { echo "FAIL: $1" >&2; exit 1; }
val()  { [ -f "$CFG" ] && grep "^$1=" "$CFG" | cut -d= -f2- || true; }
reset(){ rm -f "$CFG"; }

# ver_lt
ver_lt "v0.1.31" "v0.1.32" || fail "ver_lt 31<32"
ver_lt "v0.1.32" "v0.1.32" && fail "ver_lt 32<32 should be false"
ver_lt "" "v0.1.32" || fail "ver_lt empty<32"
ver_lt "v0.1.32.2026.06.17.abc" "v0.1.32" && fail "ver_lt suffix ignored (32<32 false)"
ver_lt "v0.1.40" "v0.1.32" && fail "ver_lt 40<32 should be false"

# fresh (OLD empty) → seeds both
reset; migrate_config ""
[ "$(val buffer_stream)" = "32m" ]  || fail "fresh: buffer_stream"
[ "$(val buffer_session)" = "256m" ] || fail "fresh: buffer_session"

# old (< introduced) → seeds
reset; migrate_config "v0.1.31"
[ "$(val buffer_session)" = "256m" ] || fail "old: buffer_session"
[ "$(val buffer_stream)" = "32m" ]   || fail "old: buffer_stream"

# current (>= introduced) → no seed
reset; migrate_config "v0.1.32"
[ -z "$(val buffer_stream)" ]  || fail "current: buffer_stream should not seed"
[ -z "$(val buffer_session)" ] || fail "current: buffer_session should not seed"

# operator value preserved (no clobber)
reset; printf 'buffer_session=128m\n' > "$CFG"; migrate_config ""
[ "$(val buffer_session)" = "128m" ] || fail "no-clobber: buffer_session changed"
[ "$(val buffer_stream)" = "32m" ]   || fail "no-clobber: buffer_stream not seeded"

echo "PASS: test-config-migrate"

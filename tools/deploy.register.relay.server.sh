#!/bin/sh
# deploy.register.relay.server.sh — manual operator pubkey register/revoke.
# Run ON the release host (or locally with REGISTRY and OPENSSL env overrides).
#
# Usage:
#   deploy.register.relay.server.sh <pubkey.pem> [label]   register a relay server key
#   deploy.register.relay.server.sh --revoke <fp>          revoke by fingerprint
#
# Fingerprint formula (must match Go's gate.Fingerprint exactly):
#   fp = hex(sha256(raw 32-byte ed25519 pubkey))[:16]  (lowercase)
#
# Environment:
#   OPENSSL   openssl binary (default: openssl — on the prod Linux host, PATH openssl is OpenSSL 3.x)
#   REGISTRY  path to sqlite3 registry db (default: /var/lib/burrowee-relay-gate/registry.db)
#   SQLITE3   sqlite3 binary (default: sqlite3)
set -eu

OPENSSL="${OPENSSL:-openssl}"
SQLITE3="${SQLITE3:-sqlite3}"
DB="${REGISTRY:-/var/lib/burrowee-relay-gate/registry.db}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Ensure the registry db directory exists and the table is present.
ensure_db() {
    mkdir -p "$(dirname "$DB")"
    "$SQLITE3" "$DB" \
        "CREATE TABLE IF NOT EXISTS pubkeys(fingerprint TEXT PRIMARY KEY, pubkey BLOB NOT NULL, label TEXT, added_at INTEGER);"
}

if [ "${1:-}" = "--revoke" ]; then
    [ $# -ge 2 ] || die "usage: $0 --revoke <fingerprint>"
    FP="$2"
    # Validate fp: must be exactly 16 lowercase hex chars (matches gate.Fingerprint output).
    echo "$FP" | grep -Eq '^[0-9a-f]{16}$' || die "invalid fingerprint: $FP"
    ensure_db
    "$SQLITE3" "$DB" "DELETE FROM pubkeys WHERE fingerprint='${FP}';"
    exit 0
fi

# Register mode.
[ $# -ge 1 ] || die "usage: $0 <pubkey.pem> [label]"
PEM="$1"
LABEL="${2:-}"
[ -f "$PEM" ] || die "pubkey PEM not found: $PEM"

TMP_RAW="$(mktemp)"
TMP_DER="$(mktemp)"
trap 'rm -f "$TMP_RAW" "$TMP_DER"' EXIT

# Extract raw 32-byte ed25519 public key from PEM: DER-encode the public key
# then take the last 32 bytes (the raw key material — the DER prefix is fixed).
# An ed25519 SPKI DER is exactly 44 bytes; reject other key types early.
"$OPENSSL" pkey -pubin -in "$PEM" -pubout -outform DER 2>/dev/null > "$TMP_DER"
DER_LEN=$(wc -c < "$TMP_DER" | tr -d ' ')
[ "$DER_LEN" = "44" ] || die "DER-encoded pubkey is $DER_LEN bytes, want 44; key must be ed25519"

tail -c 32 "$TMP_DER" > "$TMP_RAW"

RAW_LEN=$(wc -c < "$TMP_RAW" | tr -d ' ')
[ "$RAW_LEN" = "32" ] || die "extracted pubkey is $RAW_LEN bytes, want 32; is this an ed25519 key?"

# Compute fingerprint: hex(sha256(raw))[:16], lowercase.
FP=$("$OPENSSL" dgst -sha256 -binary < "$TMP_RAW" \
    | xxd -p -c256 \
    | cut -c1-16)

ensure_db

# Escape label: double any single-quotes to prevent SQL injection.
ESCAPED_LABEL=$(printf '%s' "$LABEL" | sed "s/'/''/g")

"$SQLITE3" "$DB" \
    "INSERT OR REPLACE INTO pubkeys(fingerprint,pubkey,label,added_at) VALUES('${FP}', readfile('${TMP_RAW}'), '${ESCAPED_LABEL}', strftime('%s','now'));"

printf '%s\n' "$FP"

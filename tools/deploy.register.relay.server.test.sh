#!/usr/bin/env bash
# deploy.register.relay.server.test.sh — TDD test for the pubkey register/revoke script.
# mirrors verify-no-env.test.sh style: set -euo pipefail, mktemp + trap, absolute OPENSSL.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/deploy.register.relay.server.sh"
export OPENSSL=/opt/homebrew/bin/openssl
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ── INTEROP ANCHOR ──────────────────────────────────────────────────────────
# Locks the shell sha256 formula to Go's gate.Fingerprint.
# Pinned value: all-zero 32-byte ed25519 pubkey → 66687aadf862bd77
echo "# interop-anchor: all-zero 32-byte key must hash to 66687aadf862bd77"
ANCHOR=$(head -c 32 /dev/zero | "$OPENSSL" dgst -sha256 -binary | xxd -p -c256 | cut -c1-16)
if [ "$ANCHOR" != "66687aadf862bd77" ]; then
    echo "FAIL: interop anchor mismatch: got $ANCHOR, want 66687aadf862bd77"
    echo "      shell formula drifted from Go gate.Fingerprint — whole feature at risk"
    exit 1
fi
echo "interop anchor OK: $ANCHOR"

# ── KEY GENERATION ──────────────────────────────────────────────────────────
echo "# generating ed25519 keypair"
"$OPENSSL" genpkey -algorithm ed25519 -out "$TMP/priv.pem" 2>/dev/null
"$OPENSSL" pkey -in "$TMP/priv.pem" -pubout -out "$TMP/pub.pem" 2>/dev/null

# Independently compute expected fp from the pub PEM (same formula as the script).
EXPECTED_FP=$("$OPENSSL" pkey -pubin -in "$TMP/pub.pem" -pubout -outform DER 2>/dev/null \
    | tail -c 32 \
    | "$OPENSSL" dgst -sha256 -binary \
    | xxd -p -c256 \
    | cut -c1-16)
echo "# independently computed fp: $EXPECTED_FP"

# ── REGISTER ────────────────────────────────────────────────────────────────
echo "# running script: register pub.pem with label 'test-server'"
export REGISTRY="$TMP/reg.db"
PRINTED_FP=$(bash "$SCRIPT" "$TMP/pub.pem" "test-server")
echo "# script printed fp: $PRINTED_FP"

# Assert printed fp matches independently computed fp.
if [ "$PRINTED_FP" != "$EXPECTED_FP" ]; then
    echo "FAIL: printed fp '$PRINTED_FP' != expected '$EXPECTED_FP'"
    exit 1
fi
echo "printed fp matches independently computed fp"

# Assert DB row exists and fingerprint column matches.
DB_FP=$(sqlite3 "$REGISTRY" "SELECT fingerprint FROM pubkeys")
if [ "$DB_FP" != "$PRINTED_FP" ]; then
    echo "FAIL: db fingerprint '$DB_FP' != printed '$PRINTED_FP'"
    exit 1
fi
echo "db fingerprint matches"

# Assert stored BLOB is exactly 32 bytes (Go's Lookup requires ed25519.PublicKeySize).
BLOB_LEN=$(sqlite3 "$REGISTRY" "SELECT length(pubkey) FROM pubkeys WHERE fingerprint='$PRINTED_FP'")
if [ "$BLOB_LEN" != "32" ]; then
    echo "FAIL: stored BLOB is $BLOB_LEN bytes, want 32"
    exit 1
fi
echo "stored BLOB is 32 bytes"

# Assert label was stored correctly.
STORED_LABEL=$(sqlite3 "$REGISTRY" "SELECT label FROM pubkeys WHERE fingerprint='$PRINTED_FP'")
if [ "$STORED_LABEL" != "test-server" ]; then
    echo "FAIL: stored label '$STORED_LABEL' != 'test-server'"
    exit 1
fi
echo "stored label OK"

# ── REVOKE ───────────────────────────────────────────────────────────────────
echo "# running script: --revoke $PRINTED_FP"
bash "$SCRIPT" --revoke "$PRINTED_FP"
COUNT=$(sqlite3 "$REGISTRY" "SELECT count(*) FROM pubkeys")
if [ "$COUNT" != "0" ]; then
    echo "FAIL: expected 0 rows after revoke, got $COUNT"
    exit 1
fi
echo "revoke removed the row"

# ── REVOKE INPUT VALIDATION ──────────────────────────────────────────────────
# Re-register so there is a row to protect throughout these tests.
echo "# re-registering for injection/validation tests"
bash "$SCRIPT" "$TMP/pub.pem" "anchor-row" >/dev/null
ANCHOR_FP=$(sqlite3 "$REGISTRY" "SELECT fingerprint FROM pubkeys LIMIT 1")

echo "# --revoke with invalid fp 'abc' must be rejected (non-zero exit)"
if bash "$SCRIPT" --revoke "abc" 2>/dev/null; then
    echo "FAIL: --revoke abc should have exited non-zero"
    exit 1
fi
echo "--revoke abc rejected OK"

# Verify the registry row is still intact.
ROW_COUNT=$(sqlite3 "$REGISTRY" "SELECT count(*) FROM pubkeys")
if [ "$ROW_COUNT" != "1" ]; then
    echo "FAIL: expected 1 row after rejected revoke, got $ROW_COUNT"
    exit 1
fi
echo "registry unharmed after --revoke abc"

echo "# --revoke with SQL-injection string must be rejected (non-zero exit)"
INJ="x'; DROP TABLE pubkeys; --"
if bash "$SCRIPT" --revoke "$INJ" 2>/dev/null; then
    echo "FAIL: --revoke injection string should have exited non-zero"
    exit 1
fi
echo "--revoke injection string rejected OK"

# Verify the table still exists and the row is still intact.
ROW_COUNT=$(sqlite3 "$REGISTRY" "SELECT count(*) FROM pubkeys")
if [ "$ROW_COUNT" != "1" ]; then
    echo "FAIL: expected 1 row after SQL-injection attempt, got $ROW_COUNT (table may have been dropped)"
    exit 1
fi
echo "registry unharmed after SQL-injection attempt"

# Verify it's still the same fingerprint row.
POST_INJ_FP=$(sqlite3 "$REGISTRY" "SELECT fingerprint FROM pubkeys LIMIT 1")
if [ "$POST_INJ_FP" != "$ANCHOR_FP" ]; then
    echo "FAIL: fingerprint changed after injection attempt: was $ANCHOR_FP, now $POST_INJ_FP"
    exit 1
fi
echo "anchor row fingerprint unchanged after injection attempt"

# ── NON-ED25519 KEY REJECTION ────────────────────────────────────────────────
echo "# generating RSA-2048 key to test non-ed25519 rejection"
"$OPENSSL" genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/rsa.priv.pem" 2>/dev/null
"$OPENSSL" pkey -in "$TMP/rsa.priv.pem" -pubout -out "$TMP/rsa.pub.pem" 2>/dev/null

echo "# registering RSA key must be rejected (non-zero exit)"
if bash "$SCRIPT" "$TMP/rsa.pub.pem" "rsa-test" 2>/dev/null; then
    echo "FAIL: registering an RSA key should have exited non-zero"
    exit 1
fi
echo "RSA key rejected OK"

# Verify no RSA row was stored (count unchanged at 1 from the anchor).
ROW_COUNT=$(sqlite3 "$REGISTRY" "SELECT count(*) FROM pubkeys")
if [ "$ROW_COUNT" != "1" ]; then
    echo "FAIL: expected 1 row after RSA rejection, got $ROW_COUNT"
    exit 1
fi
echo "no RSA row stored — registry still has 1 row (anchor only)"

echo "ALL OK"

# module: download-r2-only  v1
# needs:  helpers
# since:  2026-08-25

# gated_get <path> <local-filename>
#   path      : the request path, e.g. /relay/release/latest.linux-amd64.zip
#   local-filename : written under $TMP
#
# 1. Fetch a single-use nonce from the gate (unauthenticated).
# 2. Sign the exact bytes "nonce:path" with the operator key (ed25519, raw input).
# 3. Send the signed request with the three required headers.
# shellcheck disable=SC2317  # used below after definition
gated_get() {
    _path="$1"
    _out="$2"

    # Challenge: fetch nonce
    # shellcheck disable=SC2086  # $CURL is an intentional space-split command string; POSIX sh has no arrays.
    _nonce="$($CURL "$BASE/relay/challenge" \
        | sed -n 's/.*"nonce":"\([^"]*\)".*/\1/p')"
    [ -n "$_nonce" ] || fail "challenge: empty nonce from $BASE/relay/challenge"

    # Sign: nonce:path (raw input, output base64-STD via openssl base64 -A)
    # Write the message to a temp file first: openssl pkeyutl -rawin requires a
    # seekable input to determine the message length (stdin is not seekable on
    # some OpenSSL 3.x builds, producing "unable to determine file size").
    _msg="$(mktemp "${TMPDIR:-/tmp}/@brand@-sign-XXXXXX")" || fail "could not create signing temp file"
    printf '%s' "$_nonce:$_path" > "$_msg"
    _sig="$("$OPENSSL" pkeyutl -sign -inkey "$KEY" -rawin -in "$_msg" 2>/dev/null \
        | "$OPENSSL" base64 -A)"
    rm -f "$_msg"
    [ -n "$_sig" ] || fail "signing failed or returned empty signature — is $KEY a valid ed25519 PEM private key?"

    # Gated fetch: send the three required headers
    # shellcheck disable=SC2086  # $CURL is an intentional space-split command string; POSIX sh has no arrays.
    $CURL \
        -H "X-Burrowee-Key-FP: $FP" \
        -H "X-Burrowee-Nonce: $_nonce" \
        -H "X-Burrowee-Sig: $_sig" \
        -o "$TMP/$_out" \
        "$BASE$_path" \
        || fail "gated download failed: $_path — check that your key is registered on the release host"
}

ZIP="latest.${PLAT}.zip"

info "downloading relay artifact (gated)"
gated_get "$ZIP_PATH"   "$ZIP"
info "downloading SHA256SUMS.txt + signature (gated)"
gated_get "$SUMS_PATH"  "SHA256SUMS.txt"
gated_get "$SIG_PATH"   "SHA256SUMS.txt.minisig"

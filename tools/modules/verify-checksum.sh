# module: verify-checksum  v3
# needs:  sha256
# since:  2026-08-25  (v3: portable — no --ignore-missing)
# Compare ONE hash directly instead of `-c --ignore-missing` over the whole
# sums file: --ignore-missing is a 2016-era addition (Digest::SHA 5.96 /
# coreutils 8.25) and the stock shasum on an older macOS rejects it outright
# ("Unknown option: ignore-missing"). That non-zero exit came back through the
# `||` as "checksum mismatch", so every install on such a host accused a
# perfectly good zip of tampering. Picking the line by EXACT filename (awk, both
# the "hash  name" and binary "hash *name" spellings) is also stricter than the
# substring grep this replaces.
want="$(awk -v f="$ZIP" '{ n = $2; sub(/^\*/, "", n); if (n == f) { print $1; exit } }' "$TMP/SHA256SUMS.txt")"
[ -n "$want" ] \
    || fail "no checksum entry for $ZIP — release incomplete or tampered; aborting"
got="$(sha256_of "$TMP/$ZIP")" \
    || fail "neither shasum nor sha256sum found — cannot verify; aborting"
[ -n "$got" ] && [ "$want" = "$got" ] \
    || fail "checksum mismatch — aborting (zip tampered or download corrupted)"

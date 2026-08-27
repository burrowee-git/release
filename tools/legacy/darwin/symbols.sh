# symbols.sh — the one rule a darwin-amd64-legacy Mach-O must satisfy (spec §4.2).
assert_legacy_symbols() {
    local f="$1" syms
    syms="$(nm -u "$f" 2>/dev/null)" || { echo "✗ nm -u failed on $f" >&2; return 1; }
    if printf '%s\n' "$syms" | grep -q '^_SecTrustCopyCertificateChain$'; then
        echo "✗ $f still imports _SecTrustCopyCertificateChain (macOS 12+) — the legacy overlay did not apply" >&2
        return 1
    fi
    if printf '%s\n' "$syms" | grep -q '^_SecTrust' \
       && ! printf '%s\n' "$syms" | grep -q '^_SecTrustGetCertificateAtIndex$'; then
        echo "✗ $f verifies TLS but lacks _SecTrustGetCertificateAtIndex — unexpected x509 shape" >&2
        return 1
    fi
    return 0
}

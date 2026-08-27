#!/usr/bin/env bash
# overlay.test.sh — the drift guard for the darwin-amd64-legacy overlay.
# Passes only on the pinned Go minor, and only when each overlay file differs from
# the live GOROOT copy inside the hunks the overlay is allowed to own.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOROOT="$(go env GOROOT)"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 — got '$2' want '$3'"; fail=1; fi; }

want_go="$(tr -d '[:space:]' < "${HERE}/GO_VERSION")"
have_go="$(go version | awk '{print $3}')"
check "pinned go minor" "${have_go}" "${want_go}"

# Every line that differs must mention one of the symbols the overlay owns.
allowed='SecTrustCopyCertificateChain|SecTrustGetCertificateCount|SecTrustGetCertificateAtIndex|chainRef|CFArrayGetCount\(chainRef\)|CFArrayGetValueAtIndex\(chainRef|for i := 0; i < n; i\+\+|n := macos|certRef, err :=|defer macos.CFRelease\(chainRef\)|if err != nil \{|return nil, err|return int\(ret\)|^\+[[:space:]]*\}[[:space:]]*$|^[-+]\s*$'
for f in root_darwin.go:crypto/x509/root_darwin.go security.go:crypto/x509/internal/macos/security.go security.s:crypto/x509/internal/macos/security.s; do
    ours="${HERE}/${f%%:*}"; theirs="${GOROOT}/src/${f#*:}"
    stray="$(diff "${theirs}" "${ours}" | grep -E '^[<>]' | sed -E 's/^[<>] ?/+/' | grep -vE "${allowed}" || true)"
    check "only expected hunks differ: ${f%%:*}" "${stray}" ""
    check "overlay drops the 12+ import: ${f%%:*}" "$(grep -c 'SecTrustCopyCertificateChain' "${ours}")" "0"
done
check "root_darwin.go walks by index" "$(grep -c 'SecTrustGetCertificateAtIndex' "${HERE}/root_darwin.go")" "1"
check "security.s has both trampolines" "$(grep -cE 'SecTrustGetCertificate(Count|AtIndex)_trampoline\(SB\)' "${HERE}/security.s")" "2"
exit "${fail}"

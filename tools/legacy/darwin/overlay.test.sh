#!/usr/bin/env bash
# overlay.test.sh — the drift guard for the darwin-amd64-legacy overlay.
# Passes only on the pinned Go minor, and only when every diff hunk between each
# overlay file and its live GOROOT original contains at least one line naming a
# symbol the overlay owns (SecTrustCopyCertificateChain / SecTrustGetCertificateCount
# / SecTrustGetCertificateAtIndex / chainRef / CFArrayGetCount / CFArrayGetValueAtIndex).
# A hunk with none of those anchors — anywhere in the file, not just around the
# known edit sites — fails the guard, even if every individual line in it also
# happens to appear, coincidentally, inside an owned hunk elsewhere in the file.
# See README.md "What the drift guard actually guarantees" for the precise property
# and its known residual gap.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOROOT="$(go env GOROOT)"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 — got '$2' want '$3'"; fail=1; fi; }

want_go="$(tr -d '[:space:]' < "${HERE}/GO_VERSION")"
have_go="$(go version | awk '{print $3}')"
check "pinned go minor" "${have_go}" "${want_go}"

# A changed *hunk* (diff's normal-format change block, not an individual line) is
# allowed only if some line inside it — on either side of the hunk — names one of
# the symbols the overlay is allowed to touch. This is scoped per hunk rather than
# per line specifically so that generic boilerplate lines (an "if err != nil {"
# follow-on, a closing brace, a bare "return int(ret)") that sit *inside* an owned
# hunk are accepted as part of that hunk, without ever accepting such a generic
# line anywhere else in the file — which is what let an unrelated, unowned hunk
# built entirely from common Go idioms slip past a line-by-line allowlist.
anchor='SecTrustCopyCertificateChain|SecTrustGetCertificateCount|SecTrustGetCertificateAtIndex|chainRef|CFArrayGetCount|CFArrayGetValueAtIndex'

stray_hunks() {
    # $1 = theirs (live GOROOT original), $2 = ours (overlay file)
    diff "$1" "$2" | awk -v anchor="${anchor}" '
        function flush() { if (hunk != "" && hunk !~ anchor) printf "%s", hunk }
        /^[0-9]+(,[0-9]+)?[acd][0-9]+(,[0-9]+)?$/ { flush(); hunk = ""; next }
        { hunk = hunk $0 "\n" }
        END { flush() }
    '
}

for f in root_darwin.go:crypto/x509/root_darwin.go security.go:crypto/x509/internal/macos/security.go security.s:crypto/x509/internal/macos/security.s; do
    ours="${HERE}/${f%%:*}"; theirs="${GOROOT}/src/${f#*:}"
    stray="$(stray_hunks "${theirs}" "${ours}")"
    check "only owned hunks differ: ${f%%:*}" "${stray}" ""
    check "overlay drops the 12+ import: ${f%%:*}" "$(grep -c 'SecTrustCopyCertificateChain' "${ours}")" "0"
done
check "root_darwin.go walks by index" "$(grep -c 'SecTrustGetCertificateAtIndex' "${HERE}/root_darwin.go")" "1"
check "security.s has both trampolines" "$(grep -cE 'SecTrustGetCertificate(Count|AtIndex)_trampoline\(SB\)' "${HERE}/security.s")" "2"
exit "${fail}"

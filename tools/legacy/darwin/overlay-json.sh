#!/usr/bin/env bash
# overlay-json.sh <out-file> — write the go build -overlay file for the legacy variant.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOROOT="$(go env GOROOT)"
printf '{"Replace":{"%s":"%s","%s":"%s","%s":"%s"}}\n' \
    "${GOROOT}/src/crypto/x509/root_darwin.go"             "${HERE}/_src/root_darwin.go" \
    "${GOROOT}/src/crypto/x509/internal/macos/security.go" "${HERE}/_src/security.go" \
    "${GOROOT}/src/crypto/x509/internal/macos/security.s"  "${HERE}/_src/security.s" > "$1"

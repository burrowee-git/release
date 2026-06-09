#!/usr/bin/env bash
# verify-no-env.test.sh — proves tools/verify-no-env.sh fails on a stale
# (pre-zero-config) gateway binary and passes on one built from main.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${HERE}/verify-no-env.sh"
GO_BIN=/opt/homebrew/bin/go
GW=/Volumes/MacintoshED/Workstation/Coding/Burrowee/gateway/code/gateway
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

mkdir -p "${TMP}/stale"
cat > "${TMP}/stale/main.go" <<'GO'
package main
import "fmt"
func mustEnv(k string) string { return k }
func main() { fmt.Println(mustEnv("BURROWEE_RELAY_WS")) }
GO
( cd "${TMP}/stale" && "${GO_BIN}" mod init stale >/dev/null 2>&1 && "${GO_BIN}" build -o "${TMP}/stale-bin" . )

echo "# expect FAIL on the stale binary"
if "${GUARD}" "${TMP}/stale-bin"; then echo "FAIL: guard passed a stale binary"; exit 1; fi
echo "stale-binary correctly rejected"

( cd "${GW}" && CGO_ENABLED=0 "${GO_BIN}" build -trimpath -o "${TMP}/gw-bin" ./cmd/burrowee-gateway )
echo "# expect PASS on the main gateway binary"
"${GUARD}" "${TMP}/gw-bin" || { echo "FAIL: guard rejected the main gateway binary"; exit 1; }

echo "ALL OK"

#!/usr/bin/env bash
# symbols.test.sh — proves assert_legacy_symbols (spec §4.2) refuses a stock darwin build
# that still imports the macOS-12 SecTrust symbol, accepts a binary with no TLS at all, and
# accepts the same TLS program built with the legacy overlay. Also the build-scoping proof
# from spec §12: the stock build of the same source still imports the 12+ symbol.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/symbols.sh"
fail=0; check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 — got '$2' want '$3'"; fail=1; fi; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/tls" "$W/plain"
cat > "$W/tls/main.go" <<'EOF'
package main
import ("crypto/x509"; "fmt")
func main() {
	c := &x509.Certificate{Raw: []byte{0x30, 0x00}}
	_, err := c.Verify(x509.VerifyOptions{})
	fmt.Println(err)
}
EOF
cat > "$W/plain/main.go" <<'EOF'
package main
import "fmt"
func main() { fmt.Println("hi") }
EOF
for d in tls plain; do ( cd "$W/$d" && go mod init probe >/dev/null 2>&1 ); done
( cd "$W/tls"   && CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -o "$W/tls-stock" . )
( cd "$W/plain" && CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -o "$W/plain-bin" . )
bash "${HERE}/overlay-json.sh" "$W/overlay.json"
( cd "$W/tls"   && CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -overlay "$W/overlay.json" -o "$W/tls-legacy" . )
assert_legacy_symbols "$W/tls-stock"  >/dev/null 2>&1; check "stock TLS binary refused" "$?" "1"
assert_legacy_symbols "$W/plain-bin"  >/dev/null 2>&1; check "no-TLS binary accepted"   "$?" "0"
assert_legacy_symbols "$W/tls-legacy" >/dev/null 2>&1; check "overlay TLS binary accepted" "$?" "0"
exit "$fail"

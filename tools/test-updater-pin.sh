#!/usr/bin/env bash
# test-updater-pin.sh — updater_pin must return <semver>.<YYYY.MM.DD>.<sha8>
# resolved from the core/updater pin's own module metadata, and must FAIL CLOSED on
# anything it cannot resolve. A malformed stamp reaches the console catalog and the
# whole fleet, so every failure mode here aborts the cut instead.
set -uo pipefail

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — got '$2' want '$3'"; fi; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# stub_info <json> — a fake `go` whose `mod download -json` points at a .info file
# holding the given JSON, so updater_pin is tested without a real module cache.
stub_info() {
    local json="$1" dir
    dir="$(mktemp -d)"
    printf '%s' "${json}" > "${dir}/v.info"
    cat > "${dir}/go" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "mod" ] && [ "\$2" = "download" ]; then
    printf '{\n\t"Path": "github.com/burrowee-git/core/updater",\n\t"Info": "%s"\n}\n' "${dir}/v.info"
    exit 0
fi
if [ "\$1" = "list" ]; then printf 'v0.1.12'; exit 0; fi
exit 0
EOF
    chmod +x "${dir}/go"
    printf '%s' "${dir}"
}

run_pin() {
    local dir="$1"
    ( GO_BIN="${dir}/go" bash -c 'set -euo pipefail; source '"${SCRIPT_DIR}"'/updater_pin.sh; updater_pin .' ) 2>/dev/null
}

echo "→ happy path: full stamp"
D="$(stub_info '{"Version":"v0.1.12","Time":"2026-07-26T21:25:11Z","Origin":{"Hash":"65d86769b2ccd42ecf5814702ca6a8d66c375b0c"}}')"
check "full stamp" "$(run_pin "${D}")" "v0.1.12.2026.07.26.65d86769"

echo "→ freeze: same pin twice → identical stamp"
A="$(run_pin "${D}")"; B="$(run_pin "${D}")"
check "frozen across calls" "${A}" "${B}"

echo "→ fail closed: missing Time"
D="$(stub_info '{"Version":"v0.1.12","Origin":{"Hash":"65d86769b2ccd42ecf5814702ca6a8d66c375b0c"}}')"
if run_pin "${D}" >/dev/null 2>&1; then bad "missing Time must abort"; else ok "missing Time aborts"; fi

echo "→ fail closed: missing Origin.Hash"
D="$(stub_info '{"Version":"v0.1.12","Time":"2026-07-26T21:25:11Z"}')"
if run_pin "${D}" >/dev/null 2>&1; then bad "missing Hash must abort"; else ok "missing Hash aborts"; fi

echo "→ fail closed: short Hash"
D="$(stub_info '{"Version":"v0.1.12","Time":"2026-07-26T21:25:11Z","Origin":{"Hash":"65d867"}}')"
if run_pin "${D}" >/dev/null 2>&1; then bad "short Hash must abort"; else ok "short Hash aborts"; fi

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]

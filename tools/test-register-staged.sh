#!/usr/bin/env bash
# test-register-staged.sh — offline tests for the register_staged hook (Phase C).
#
# Tests:
#   1. dry-run: with DRY_RUN=1 and BURROWEE_CONSOLE_URL/TOKEN set, register_staged
#      prints "would POST .../api/v1/manage/releases" with a body containing
#      "component":"cli" and "prerelease":true, and does NOT call curl (asserted
#      via a PATH-shadowed curl stub that exits 99 if invoked).
#   2. configured POST: with BURROWEE_CONSOLE_URL pointed at a local one-shot
#      Python 3 HTTP server, register_staged posts the correct body + Bearer.
#      If python3 is absent, this test is skipped (not a failure).
#   3. unconfigured skip: with BURROWEE_CONSOLE_URL/TOKEN unset, register_staged
#      prints the skip warning and returns 0.
#   4. relay-specific: gated=true, empty github_release, host-path artifacts.
#
# All tests source register_staged in isolation (no real release.sh run required
# for tests 2-4; test 1 verifies the function's dry-run branch directly).
#
# Coverage limits:
#   - Tests 1-4 exercise register_staged's 4 branches offline.
#   - The extract_register_staged helper pulls the function out of release.sh by
#     text; if release.sh's function boundary changes, the helper needs updating.
#   - Full end-to-end (real release.sh --dry-run) is not exercised here to avoid
#     the minisign + source-worktree dependency; see test-e2e.sh for that.
#
# Exits 0 iff all non-skipped tests pass.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# ---- tool paths (the Burrowee per-dir hook strips /opt/homebrew/bin) ---------
export PATH="/opt/homebrew/bin:${PATH}"
SHA256=""
if command -v shasum >/dev/null 2>&1; then
    SHA256="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
    SHA256="sha256sum"
else
    echo "✗ neither shasum nor sha256sum found" >&2; exit 1
fi

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\n✗ TEST FAILED: %s\n' "$*" >&2; exit 1; }
skip() { printf '\n⚠ SKIPPED: %s\n' "$*"; }

# ---- workdir + cleanup -------------------------------------------------------
W="$(mktemp -d "${TMPDIR:-/tmp}/test-register-staged-XXXXXX")"
SERVER_PID=""
cleanup() {
    [ -z "${SERVER_PID}" ] || kill "${SERVER_PID}" 2>/dev/null || true
    rm -rf "${W}"
}
trap cleanup EXIT INT TERM

# ---- shared config -----------------------------------------------------------
TARGETS=(
    "darwin arm64"
    "darwin amd64"
    "linux arm64"
    "linux amd64"
)
RELEASE_REPO="${BURROWEE_RELEASE_REPO:-burrowee-git/release}"
RELAY_PRIVATE_DIR="${RELAY_PRIVATE_DIR:-/srv/relay-releases}"

# =============================================================================
# HELPERS
# =============================================================================

# extract_register_staged <out_file>
# Extracts the register_staged() function body from release.sh into a sourceable
# file by locating the Phase-C block marker and copying through the function.
extract_register_staged() {
    local out="$1"
    # Pull from the Phase-C comment block through (and including) register_staged's
    # closing brace. We detect the function by tracking brace depth.
    python3 - "${REPO_ROOT}/tools/release.sh" "${out}" <<'PYEOF'
import sys

src_path, out_path = sys.argv[1], sys.argv[2]
lines = open(src_path).readlines()

in_phase_c = False
in_func = False
depth = 0
result = []

for line in lines:
    # Start capturing at the Phase-C comment.
    if '# ---- console registration (Phase C)' in line:
        in_phase_c = True
    if not in_phase_c:
        continue

    # Detect entering register_staged().
    if line.startswith('register_staged()'):
        in_func = True
        depth = 0

    result.append(line)

    if in_func:
        depth += line.count('{') - line.count('}')
        if depth <= 0 and len(result) > 2:
            # Closing brace of register_staged reached; stop.
            break

    # Stop capturing at the next ---- block (a different function) once
    # we've left the Phase-C section (but haven't yet found register_staged).
    if in_phase_c and not in_func and line.startswith('# ----') and 'console registration' not in line:
        break

open(out_path, 'w').writelines(result)
PYEOF
}

# make_stage <dir> <comp>
# Creates a minimal stage dir with 4 platform zips + SHA256SUMS.txt matching
# release.sh output:
#   public comps: burrowee-<comp>-<os>-<arch>.zip
#   relay:        latest.<os>-<arch>.zip
make_stage() {
    local dir="$1" comp="$2"
    mkdir -p "${dir}"
    local pair os arch zip_name
    for pair in "${TARGETS[@]}"; do
        read -r os arch <<<"${pair}"
        if [ "${comp}" = relay ]; then
            zip_name="latest.${os}-${arch}.zip"
        else
            zip_name="burrowee-${comp}-${os}-${arch}.zip"
        fi
        # Write a tiny deterministic zip with a dummy file.
        local tmp_content="${dir}/.dummy-${os}-${arch}"
        printf 'dummy-%s-%s\n' "${os}" "${arch}" > "${tmp_content}"
        ( cd "${dir}" && zip -q "${zip_name}" "./.dummy-${os}-${arch}" )
        rm -f "${tmp_content}"
    done
    # Compute SHA256SUMS.txt.
    # shellcheck disable=SC2086
    ( cd "${dir}" && ${SHA256} *.zip | sort > SHA256SUMS.txt )
}

# run_register_staged <extract_file> <env_pairs...> -- <args...>
# Sources extract_file in a subshell with the given env, calls register_staged.
# Returns the combined stdout+stderr output.
run_fn() {
    local extract="$1"; shift
    # Remaining args are passed verbatim as the bash -c script body.
    bash -c "$@" 2>&1 || true
}

# =============================================================================
# TEST 1 — dry-run: prints would POST, curl stub never called.
# =============================================================================
say "TEST 1 — dry-run: would POST printed, curl NOT called"

# PATH-shadowed curl stub that fails loudly if invoked.
mkdir -p "${W}/bin"
cat > "${W}/bin/curl" <<'STUB'
#!/bin/sh
echo "✗ curl was called during dry-run — test FAILED" >&2
exit 99
STUB
chmod +x "${W}/bin/curl"

STAGE1="${W}/stage1"
make_stage "${STAGE1}" "cli"
EXTRACT1="${W}/fn1.sh"
extract_register_staged "${EXTRACT1}"

RESULT1="$(
    PATH="${W}/bin:${PATH}" \
    DRY_RUN=1 \
    BURROWEE_CONSOLE_URL="https://console.example.com" \
    BURROWEE_CONSOLE_RELEASE_TOKEN="tok-test" \
    RELEASE_REPO="${RELEASE_REPO}" \
    RELAY_PRIVATE_DIR="${RELAY_PRIVATE_DIR}" \
    SHA256="${SHA256}" \
    bash -c "
        TARGETS=(\"darwin arm64\" \"darwin amd64\" \"linux arm64\" \"linux amd64\")
        . '${EXTRACT1}'
        register_staged cli v0.1.0.2026.06.17.abcd1234 0.1.0 '${STAGE1}' cli/v0.1.0.2026.06.17.abcd1234
    " 2>&1
)"

printf '%s\n' "${RESULT1}" | grep -q 'would POST' \
    || die "TEST 1: 'would POST' line not found. Output:\n${RESULT1}"
printf '%s\n' "${RESULT1}" | grep -q '"component":"cli"' \
    || die "TEST 1: '\"component\":\"cli\"' not found. Output:\n${RESULT1}"
printf '%s\n' "${RESULT1}" | grep -q '"prerelease":true' \
    || die "TEST 1: '\"prerelease\":true' not found. Output:\n${RESULT1}"
printf '%s\n' "${RESULT1}" | grep -q '/api/v1/manage/releases' \
    || die "TEST 1: URL '/api/v1/manage/releases' not found. Output:\n${RESULT1}"

echo "✓ TEST 1 PASSED — dry-run prints would POST with correct fields; curl not called"

# =============================================================================
# TEST 2 — configured POST: correct body + Bearer to a local HTTP stub.
# =============================================================================
say "TEST 2 — configured POST: correct body + Bearer sent to local stub"

PYTHON_BIN=""
command -v python3 >/dev/null 2>&1 && PYTHON_BIN="python3"

if [ -z "${PYTHON_BIN}" ]; then
    skip "TEST 2 — python3 not found; skipping live-stub POST test"
else
    TEST2_PORT="${REGISTER_TEST_PORT:-18543}"
    REQUEST_FILE="${W}/request.txt"

    # One-shot HTTP server: captures POST body + headers → file, replies 201, exits.
    SERVER_SCRIPT="${W}/stub_server.py"
    cat > "${SERVER_SCRIPT}" <<PYEOF
import socketserver, http.server, sys, threading

port = int(sys.argv[1])
req_file = sys.argv[2]
done = threading.Event()

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length).decode()
        auth = self.headers.get('Authorization', '')
        with open(req_file, 'w') as f:
            f.write('PATH: ' + self.path + '\n')
            f.write('AUTH: ' + auth + '\n')
            f.write('BODY: ' + body + '\n')
        self.send_response(201)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{"id":"test-id"}')
        done.set()
    def log_message(self, *a): pass

class ReuseTCPServer(socketserver.TCPServer):
    allow_reuse_address = True

with ReuseTCPServer(('127.0.0.1', port), Handler) as s:
    t = threading.Thread(target=s.serve_forever)
    t.daemon = True
    t.start()
    done.wait(timeout=15)
    s.shutdown()
PYEOF

    "${PYTHON_BIN}" "${SERVER_SCRIPT}" "${TEST2_PORT}" "${REQUEST_FILE}" &
    SERVER_PID=$!

    # Poll until the server is accepting connections (up to 5 s).
    i=0
    until curl -fsS --connect-timeout 0.5 "http://127.0.0.1:${TEST2_PORT}/" \
          -o /dev/null 2>/dev/null || [ "${i}" -ge 100 ]; do
        i=$((i+1)); sleep 0.05
    done
    # A GET to the root will 404 (no GET handler) — we just need it to connect.
    # That's fine; we only need it listening before our POST.

    STAGE2="${W}/stage2"
    make_stage "${STAGE2}" "gateway"
    EXTRACT2="${W}/fn2.sh"
    extract_register_staged "${EXTRACT2}"

    DRY_RUN=0 \
    BURROWEE_CONSOLE_URL="http://127.0.0.1:${TEST2_PORT}" \
    BURROWEE_CONSOLE_RELEASE_TOKEN="tok-bearer-test" \
    RELEASE_REPO="${RELEASE_REPO}" \
    RELAY_PRIVATE_DIR="${RELAY_PRIVATE_DIR}" \
    SHA256="${SHA256}" \
    bash -c "
        TARGETS=(\"darwin arm64\" \"darwin amd64\" \"linux arm64\" \"linux amd64\")
        . '${EXTRACT2}'
        register_staged gateway v0.1.0.2026.06.17.abcd5678 0.1.0 '${STAGE2}' gateway/v0.1.0.2026.06.17.abcd5678
    " >/dev/null 2>&1 || true

    # Wait for the server to write the file (up to 5 s).
    i=0
    until [ -f "${REQUEST_FILE}" ] || [ "${i}" -ge 100 ]; do
        i=$((i+1)); sleep 0.05
    done
    wait "${SERVER_PID}" 2>/dev/null || true
    SERVER_PID=""

    [ -f "${REQUEST_FILE}" ] || die "TEST 2: request file not written — POST may not have reached the server"
    REQUEST_CONTENT="$(cat "${REQUEST_FILE}")"

    printf '%s\n' "${REQUEST_CONTENT}" | grep -q '/api/v1/manage/releases' \
        || die "TEST 2: wrong path. Got:\n${REQUEST_CONTENT}"
    printf '%s\n' "${REQUEST_CONTENT}" | grep -q 'Bearer tok-bearer-test' \
        || die "TEST 2: missing/wrong Authorization header. Got:\n${REQUEST_CONTENT}"
    printf '%s\n' "${REQUEST_CONTENT}" | grep -q '"component":"gateway"' \
        || die "TEST 2: expected component=gateway. Got:\n${REQUEST_CONTENT}"
    printf '%s\n' "${REQUEST_CONTENT}" | grep -q '"prerelease":true' \
        || die "TEST 2: expected prerelease=true. Got:\n${REQUEST_CONTENT}"
    printf '%s\n' "${REQUEST_CONTENT}" | grep -q '"gated":false' \
        || die "TEST 2: expected gated=false for gateway. Got:\n${REQUEST_CONTENT}"
    printf '%s\n' "${REQUEST_CONTENT}" | grep -q 'github.com' \
        || die "TEST 2: expected GitHub URL in artifacts. Got:\n${REQUEST_CONTENT}"

    echo "✓ TEST 2 PASSED — POST sent with correct path, Bearer, component, gated, prerelease"
fi

# =============================================================================
# TEST 3 — unconfigured skip: warning printed, returns 0.
# =============================================================================
say "TEST 3 — unconfigured skip: prints warning, returns 0"

STAGE3="${W}/stage3"
make_stage "${STAGE3}" "edge"
EXTRACT3="${W}/fn3.sh"
extract_register_staged "${EXTRACT3}"

TEST3_OUT="$(
    env -u BURROWEE_CONSOLE_URL -u BURROWEE_CONSOLE_RELEASE_TOKEN \
    DRY_RUN=0 \
    RELEASE_REPO="${RELEASE_REPO}" \
    RELAY_PRIVATE_DIR="${RELAY_PRIVATE_DIR}" \
    SHA256="${SHA256}" \
    bash -c "
        TARGETS=(\"darwin arm64\" \"darwin amd64\" \"linux arm64\" \"linux amd64\")
        . '${EXTRACT3}'
        register_staged edge v0.1.0.2026.06.17.abcdefgh 0.1.0 '${STAGE3}' edge/v0.1.0.2026.06.17.abcdefgh
        echo 'exit_code:0'
    " 2>&1
)"

printf '%s\n' "${TEST3_OUT}" | grep -q 'console registration skipped' \
    || die "TEST 3: skip warning not found. Output:\n${TEST3_OUT}"
printf '%s\n' "${TEST3_OUT}" | grep -q 'exit_code:0' \
    || die "TEST 3: function returned non-zero (shell exited before sentinel echo). Output:\n${TEST3_OUT}"

echo "✓ TEST 3 PASSED — unconfigured env: skip warning printed, return 0"

# =============================================================================
# TEST 4 — relay: gated=true, empty github_release, host-path artifacts.
# =============================================================================
say "TEST 4 — relay: gated=true, empty github_release, host paths in artifacts"

STAGE4="${W}/stage4"
make_stage "${STAGE4}" "relay"
EXTRACT4="${W}/fn4.sh"
extract_register_staged "${EXTRACT4}"

RESULT4="$(
    DRY_RUN=1 \
    BURROWEE_CONSOLE_URL="https://console.example.com" \
    BURROWEE_CONSOLE_RELEASE_TOKEN="tok-relay" \
    RELEASE_REPO="${RELEASE_REPO}" \
    RELAY_PRIVATE_DIR="/srv/relay-releases" \
    SHA256="${SHA256}" \
    bash -c "
        TARGETS=(\"darwin arm64\" \"darwin amd64\" \"linux arm64\" \"linux amd64\")
        . '${EXTRACT4}'
        register_staged relay v0.1.0.2026.06.17.abcd9999 0.1.0 '${STAGE4}'
    " 2>&1
)"

printf '%s\n' "${RESULT4}" | grep -q '"gated":true' \
    || die "TEST 4: expected gated=true for relay. Output:\n${RESULT4}"
printf '%s\n' "${RESULT4}" | grep -q '"github_release":""' \
    || die "TEST 4: expected empty github_release for relay. Output:\n${RESULT4}"
printf '%s\n' "${RESULT4}" | grep -q '/srv/relay-releases/' \
    || die "TEST 4: expected relay host path in artifacts. Output:\n${RESULT4}"
printf '%s\n' "${RESULT4}" | grep -q '"component":"relay"' \
    || die "TEST 4: expected component=relay. Output:\n${RESULT4}"

echo "✓ TEST 4 PASSED — relay: gated=true, empty github_release, host-path artifacts"

# =============================================================================
echo ""
echo "✓ ALL TESTS PASSED"

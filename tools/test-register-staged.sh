#!/usr/bin/env bash
# test-register-staged.sh — offline tests for the register_staged hook (Phase C).
#
# What register_staged ACTUALLY does (post-relay-cut, current code):
#   - Builds the console-register JSON BODY from the four per-platform zips in
#     <stage_dir> (component/version/semver/gated/artifacts/refs/…), escaping
#     every string field through json_escape (now `jq -Rs`, not hand-rolled sed).
#   - On DRY_RUN=1: prints "would register … via burrowee-release-register" plus
#     the body, and returns 0 — it does NOT POST.
#   - On a real run: writes .register-payload.json and shells out to the Go
#     helper `burrowee-release-register register --payload-file …`, which performs
#     the pubkey/nonce/Ed25519-sig handshake against the console. register_staged
#     itself sends NO HTTP and NO Bearer token — so this test does NOT assert a
#     curl POST or an Authorization header (the prior version did; that path is
#     dead). The handshake itself is covered by the Go register package tests
#     (internal/register/register_test.go).
#
# Tests (all offline, via register_staged's DRY_RUN preview branch):
#   1. dry-run public (cli): prints "would register", body carries
#      "component":"cli", "prerelease":true, "gated":false, a GitHub artifact URL,
#      and is VALID JSON. Asserts curl is NOT invoked.
#   2. relay: gated=true, empty github_release, R2-key artifacts, valid JSON.
#   3. unconfigured skip: with no config.toml, a real (non-dry) run prints the
#      skip warning and returns 0 (and still does not POST).
#   4. json_escape robustness (H1): a stamp containing a double-quote, backslash,
#      newline, tab, and a control char still produces a body that parses as
#      valid JSON (the old sed escaper would have emitted broken JSON here).
#
# Coverage limits:
#   - The extract_register_staged helper pulls the function out of release.sh by
#     text; if release.sh's function boundary changes, the helper needs updating.
#   - Full end-to-end (real release.sh --dry-run) is not exercised here to avoid
#     the minisign + source-worktree dependency; see test-e2e.sh for that.
#   - The real console POST handshake is not exercised in shell (it lives in the
#     Go helper); see internal/register/register_test.go.
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
# json_escape (in release.sh) requires jq; the tests source that function, so jq
# must be present here too.
command -v jq >/dev/null 2>&1 || { echo "✗ jq not found (register_staged's json_escape needs it)" >&2; exit 1; }

# JSON validator: prefer jq, fall back to python3.
json_ok() {
    if command -v jq >/dev/null 2>&1; then
        jq -e . >/dev/null 2>&1
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1
    else
        return 0
    fi
}

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\n✗ TEST FAILED: %s\n' "$*" >&2; exit 1; }
skip() { printf '\n⚠ SKIPPED: %s\n' "$*"; }

# ---- workdir + cleanup -------------------------------------------------------
W="$(mktemp -d "${TMPDIR:-/tmp}/test-register-staged-XXXXXX")"
cleanup() { rm -rf "${W}"; }
trap cleanup EXIT INT TERM

# ---- shared config -----------------------------------------------------------
TARGETS=(
    "darwin arm64"
    "darwin amd64"
    "linux arm64"
    "linux amd64"
)
RELEASE_REPO="${BURROWEE_RELEASE_REPO:-burrowee-git/release}"

# Real component source worktrees. Task 2's updater_version resolution now
# hard-fails (mirrors dispatcher_version's nullability — see register_staged's
# resolve_updater_pin) rather than silently swallowing an unresolvable
# core/updater pin, so every test that exercises a non-agent component must
# pass a REAL src_dir (a bogus placeholder path would make register_staged
# fail loudly, which is now correct behavior, not a test artifact).
CLI_SRC="${BURROWEE_SRC_CLI:-/Volumes/MacintoshED/Workstation/Coding/Burrowee/cli/code/cli}"
EDGE_SRC="${BURROWEE_SRC_EDGE:-/Volumes/MacintoshED/Workstation/Coding/Burrowee/edge/code/edge}"
RELAY_SRC="${BURROWEE_SRC_RELAY:-/Volumes/MacintoshED/Workstation/Coding/Burrowee/relay/code/relay}"
AGENT_SRC="${BURROWEE_SRC_AGENT:-/Volumes/MacintoshED/Workstation/Coding/Burrowee/agent/code/agent}"
# go env for real pin resolution (mirrors release.sh's own GO_BIN + the
# private-module env the repo's other tests already export).
GO_ENV=(GO_BIN=/opt/homebrew/bin/go GOTOOLCHAIN=go1.26.5 GOPRIVATE="github.com/burrowee-git/*")

# =============================================================================
# HELPERS
# =============================================================================

# extract_register_staged <out_file>
# Extracts the register_staged() function body from release.sh into a sourceable
# file by locating the Phase-C block marker and copying through the function.
extract_register_staged() {
    local out="$1"
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

# body_of <dry_run_output>
# Extracts the JSON body from register_staged's dry-run preview ("  body: {…}").
body_of() {
    printf '%s\n' "$1" | sed -n 's/^  body: //p' | head -n1
}

# =============================================================================
# TEST 1 — dry-run public (cli): would register, valid JSON, no curl.
# =============================================================================
say "TEST 1 — dry-run public: would register, valid JSON, curl NOT called"

# PATH-shadowed curl stub that fails loudly if invoked (register_staged must not
# POST — the Go helper does, and only on a real run).
mkdir -p "${W}/bin"
cat > "${W}/bin/curl" <<'STUB'
#!/bin/sh
echo "✗ curl was called by register_staged — it must not POST directly" >&2
exit 99
STUB
chmod +x "${W}/bin/curl"

STAGE1="${W}/stage1"
make_stage "${STAGE1}" "cli"
EXTRACT1="${W}/fn1.sh"
extract_register_staged "${EXTRACT1}"

RESULT1="$(
    env \
    PATH="${W}/bin:${PATH}" \
    "${GO_ENV[@]}" \
    DRY_RUN=1 \
    RELEASE_REPO="${RELEASE_REPO}" \
    SHA256="${SHA256}" \
    bash -c "
        TARGETS=(\"darwin arm64\" \"darwin amd64\" \"linux arm64\" \"linux amd64\")
        . '${EXTRACT1}'
        register_staged cli v0.1.0.2026.06.17.abcd1234 0.1.0 '${STAGE1}' '${CLI_SRC}' cli/v0.1.0.2026.06.17.abcd1234
    " 2>&1
)"

printf '%s\n' "${RESULT1}" | grep -q 'would register' \
    || die "TEST 1: 'would register' line not found. Output:\n${RESULT1}"
printf '%s\n' "${RESULT1}" | grep -q '"component":"cli"' \
    || die "TEST 1: '\"component\":\"cli\"' not found. Output:\n${RESULT1}"
printf '%s\n' "${RESULT1}" | grep -q '"prerelease":true' \
    || die "TEST 1: '\"prerelease\":true' not found. Output:\n${RESULT1}"
printf '%s\n' "${RESULT1}" | grep -q '"gated":false' \
    || die "TEST 1: '\"gated\":false' not found. Output:\n${RESULT1}"
printf '%s\n' "${RESULT1}" | grep -q 'github.com' \
    || die "TEST 1: expected GitHub artifact URL. Output:\n${RESULT1}"
printf '%s' "$(body_of "${RESULT1}")" | json_ok \
    || die "TEST 1: register body is not valid JSON. Output:\n${RESULT1}"

echo "✓ TEST 1 PASSED — dry-run prints would register with correct fields, valid JSON, curl not called"

# =============================================================================
# TEST 2 — relay: gated=true, empty github_release, R2-key artifacts.
# =============================================================================
say "TEST 2 — relay: gated=true, empty github_release, R2 keys in artifacts"

STAGE2="${W}/stage2"
make_stage "${STAGE2}" "relay"
EXTRACT2="${W}/fn2.sh"
extract_register_staged "${EXTRACT2}"

RESULT2="$(
    env \
    "${GO_ENV[@]}" \
    DRY_RUN=1 \
    RELEASE_REPO="${RELEASE_REPO}" \
    SHA256="${SHA256}" \
    bash -c "
        TARGETS=(\"darwin arm64\" \"darwin amd64\" \"linux arm64\" \"linux amd64\")
        . '${EXTRACT2}'
        register_staged relay v0.1.0.2026.06.17.abcd9999 0.1.0 '${STAGE2}' '${RELAY_SRC}'
    " 2>&1
)"

printf '%s\n' "${RESULT2}" | grep -q '"gated":true' \
    || die "TEST 2: expected gated=true for relay. Output:\n${RESULT2}"
printf '%s\n' "${RESULT2}" | grep -q '"github_release":""' \
    || die "TEST 2: expected empty github_release for relay. Output:\n${RESULT2}"
printf '%s\n' "${RESULT2}" | grep -q 'relay/v0.1.0.2026.06.17.abcd9999/' \
    || die "TEST 2: expected relay R2 key in artifacts. Output:\n${RESULT2}"
printf '%s\n' "${RESULT2}" | grep -q '"component":"relay"' \
    || die "TEST 2: expected component=relay. Output:\n${RESULT2}"
printf '%s' "$(body_of "${RESULT2}")" | json_ok \
    || die "TEST 2: relay register body is not valid JSON. Output:\n${RESULT2}"

echo "✓ TEST 2 PASSED — relay: gated=true, empty github_release, R2-key artifacts, valid JSON"

# =============================================================================
# TEST 3 — unconfigured skip: real run with no config.toml → warning, return 0.
# =============================================================================
say "TEST 3 — unconfigured skip: prints warning, returns 0, no curl"

STAGE3="${W}/stage3"
make_stage "${STAGE3}" "edge"
EXTRACT3="${W}/fn3.sh"
extract_register_staged "${EXTRACT3}"

# Point HOME at an empty dir so ~/.burrowee/release/config.toml is absent → skip.
FAKE_HOME="${W}/fakehome"
mkdir -p "${FAKE_HOME}"

TEST3_OUT="$(
    env \
    PATH="${W}/bin:${PATH}" \
    HOME="${FAKE_HOME}" \
    "${GO_ENV[@]}" \
    DRY_RUN=0 \
    RELEASE_REPO="${RELEASE_REPO}" \
    SHA256="${SHA256}" \
    bash -c "
        TARGETS=(\"darwin arm64\" \"darwin amd64\" \"linux arm64\" \"linux amd64\")
        . '${EXTRACT3}'
        register_staged edge v0.1.0.2026.06.17.abcdefgh 0.1.0 '${STAGE3}' '${EDGE_SRC}' edge/v0.1.0.2026.06.17.abcdefgh
        echo 'exit_code:0'
    " 2>&1
)"

printf '%s\n' "${TEST3_OUT}" | grep -q 'console registration skipped' \
    || die "TEST 3: skip warning not found. Output:\n${TEST3_OUT}"
printf '%s\n' "${TEST3_OUT}" | grep -q 'exit_code:0' \
    || die "TEST 3: function returned non-zero (shell exited before sentinel echo). Output:\n${TEST3_OUT}"

echo "✓ TEST 3 PASSED — unconfigured env: skip warning printed, return 0"

# =============================================================================
# TEST 4 — json_escape robustness (H1): control chars / quotes → valid JSON.
# =============================================================================
say "TEST 4 — H1: stamp with quote/backslash/newline/tab/control → valid JSON"

STAGE4="${W}/stage4"
make_stage "${STAGE4}" "cli"
EXTRACT4="${W}/fn4.sh"
extract_register_staged "${EXTRACT4}"

# A pathological version/semver carrying every class the old sed escaper missed:
# embedded double-quote, backslash, newline, tab, and a U+0001 control char.
EVIL_STAMP="$(printf 'v0.1.0"evil\\back\nNL\tTAB\001CTRL')"

RESULT4="$(
    env \
    "${GO_ENV[@]}" \
    DRY_RUN=1 \
    RELEASE_REPO="${RELEASE_REPO}" \
    SHA256="${SHA256}" \
    EVIL_STAMP="${EVIL_STAMP}" \
    bash -c '
        TARGETS=("darwin arm64" "darwin amd64" "linux arm64" "linux amd64")
        . '"'${EXTRACT4}'"'
        register_staged cli "${EVIL_STAMP}" "${EVIL_STAMP}" '"'${STAGE4}'"' '"'${CLI_SRC}'"' "cli/${EVIL_STAMP}"
    ' 2>&1
)"

BODY4="$(body_of "${RESULT4}")"
[ -n "${BODY4}" ] || die "TEST 4: no body emitted. Output:\n${RESULT4}"
printf '%s' "${BODY4}" | json_ok \
    || die "TEST 4: body with control chars is NOT valid JSON — json_escape regressed. Body:\n${BODY4}"
# Confirm the control char was actually escaped (), not passed through raw.
printf '%s' "${BODY4}" | grep -q '\\u0001' \
    || die "TEST 4: control char U+0001 not escaped to \\u0001 in body. Body:\n${BODY4}"

echo "✓ TEST 4 PASSED — json_escape handles quote/backslash/newline/tab/control; body is valid JSON"

# =============================================================================
# TEST 5 — updater_version (Task 2): public comp (edge) body carries the
# resolved core/updater pin from its real source worktree (root module).
# =============================================================================
say "TEST 5 — updater_version: edge body carries the core/updater pin (root module)"

if [ ! -d "${EDGE_SRC}" ]; then
    skip "TEST 5: edge source worktree not found at ${EDGE_SRC} — cannot resolve a real core/updater pin"
else
    STAGE5="${W}/stage5"
    make_stage "${STAGE5}" "edge"
    EXTRACT5="${W}/fn5.sh"
    extract_register_staged "${EXTRACT5}"

    # The pin this test expects the body to carry: same resolution the
    # implementation uses (go list -m from the component's root module dir).
    edge_pin="$(cd "${EDGE_SRC}" && GOTOOLCHAIN=go1.26.5 GOPRIVATE="github.com/burrowee-git/*" /opt/homebrew/bin/go list -m -f '{{.Version}}' github.com/burrowee-git/core/updater)"

    RESULT5="$(
        env \
        "${GO_ENV[@]}" \
        DRY_RUN=1 \
        RELEASE_REPO="${RELEASE_REPO}" \
        SHA256="${SHA256}" \
        bash -c "
            TARGETS=(\"darwin arm64\" \"darwin amd64\" \"linux arm64\" \"linux amd64\")
            . '${EXTRACT5}'
            register_staged edge v0.1.0.2026.06.17.edgepin 0.1.0 '${STAGE5}' '${EDGE_SRC}' edge/v0.1.0.2026.06.17.edgepin
        " 2>&1
    )"

    printf '%s\n' "${RESULT5}" | grep -q "\"updater_version\":\"${edge_pin}\"" \
        || die "TEST 5: updater_version '${edge_pin}' missing from register body. Output:\n${RESULT5}"
    printf '%s' "$(body_of "${RESULT5}")" | json_ok \
        || die "TEST 5: edge register body is not valid JSON. Output:\n${RESULT5}"

    echo "✓ TEST 5 PASSED — updater_version resolves the real core/updater pin (root module) for edge"
fi

# =============================================================================
# TEST 6 — updater_version (Task 2): relay body carries the resolved
# core/updater pin from the NESTED cli module (cli/go.mod), not the relay
# root module (which does not pin core/updater directly).
# =============================================================================
say "TEST 6 — updater_version: relay body carries the core/updater pin (nested cli module)"

if [ ! -d "${RELAY_SRC}/cli" ]; then
    skip "TEST 6: relay source worktree (nested cli module) not found at ${RELAY_SRC}/cli — cannot resolve a real core/updater pin"
else
    STAGE6="${W}/stage6"
    make_stage "${STAGE6}" "relay"
    EXTRACT6="${W}/fn6.sh"
    extract_register_staged "${EXTRACT6}"

    relay_pin="$(cd "${RELAY_SRC}/cli" && GOTOOLCHAIN=go1.26.5 GOPRIVATE="github.com/burrowee-git/*" /opt/homebrew/bin/go list -m -f '{{.Version}}' github.com/burrowee-git/core/updater)"

    RESULT6="$(
        env \
        "${GO_ENV[@]}" \
        DRY_RUN=1 \
        RELEASE_REPO="${RELEASE_REPO}" \
        SHA256="${SHA256}" \
        bash -c "
            TARGETS=(\"darwin arm64\" \"darwin amd64\" \"linux arm64\" \"linux amd64\")
            . '${EXTRACT6}'
            register_staged relay v0.1.0.2026.06.17.relaypin 0.1.0 '${STAGE6}' '${RELAY_SRC}'
        " 2>&1
    )"

    printf '%s\n' "${RESULT6}" | grep -q "\"updater_version\":\"${relay_pin}\"" \
        || die "TEST 6: updater_version '${relay_pin}' missing from relay register body (nested cli module). Output:\n${RESULT6}"

    echo "✓ TEST 6 PASSED — updater_version resolves the real core/updater pin (nested cli module) for relay"
fi

# =============================================================================
# TEST 7 — updater_version (Task 2): agent has no core/updater dependency (no
# burrowee-agent-updater binary exists) — must not crash register_staged, and
# updater_version must be emitted as an empty string rather than aborting the
# whole release under `set -euo pipefail`.
# =============================================================================
say "TEST 7 — updater_version: agent (no core/updater dep) does not crash, emits empty string"

if [ ! -d "${AGENT_SRC}" ]; then
    skip "TEST 7: agent source worktree not found at ${AGENT_SRC}"
else
    STAGE7="${W}/stage7"
    make_stage "${STAGE7}" "agent"
    EXTRACT7="${W}/fn7.sh"
    extract_register_staged "${EXTRACT7}"

    RESULT7="$(
        env \
        "${GO_ENV[@]}" \
        DRY_RUN=1 \
        RELEASE_REPO="${RELEASE_REPO}" \
        SHA256="${SHA256}" \
        bash -c "
            TARGETS=(\"darwin arm64\" \"darwin amd64\" \"linux arm64\" \"linux amd64\")
            . '${EXTRACT7}'
            register_staged agent v0.1.0.2026.06.17.agentpin 0.1.0 '${STAGE7}' '${AGENT_SRC}' agent/v0.1.0.2026.06.17.agentpin
            echo 'exit_code:0'
        " 2>&1
    )"

    printf '%s\n' "${RESULT7}" | grep -q 'exit_code:0' \
        || die "TEST 7: register_staged crashed for agent (no core/updater dep). Output:\n${RESULT7}"
    printf '%s\n' "${RESULT7}" | grep -q '"updater_version":""' \
        || die "TEST 7: expected empty updater_version for agent. Output:\n${RESULT7}"
    printf '%s' "$(body_of "${RESULT7}")" | json_ok \
        || die "TEST 7: agent register body is not valid JSON. Output:\n${RESULT7}"

    echo "✓ TEST 7 PASSED — agent: no crash, updater_version emitted as empty string"
fi

# =============================================================================
# TEST 8 — updater_version (Task 2 fix-round-1): an unresolvable core/updater
# pin for a NON-agent component must FAIL LOUDLY (non-zero exit + a clear
# stderr diagnostic), never silently degrade to an empty updater_version.
# This is the negative case that a prior version of this code got wrong (a
# `2>/dev/null || updater_ver=""` swallow around `go list -m`), which could
# have masked a real regression (e.g. a transient GOPRIVATE/auth/cache
# failure) as a quietly-empty field in a live cut.
#
# Fixture: register cli (a component that DOES require core/updater) but
# point its src_dir at the AGENT worktree, whose go.mod has no core/updater
# dependency at all — go list -m deterministically fails offline with
# "not a known dependency", no network required.
# =============================================================================
say "TEST 8 — updater_version: unresolvable pin FAILS loudly for a non-agent component"

if [ ! -d "${AGENT_SRC}" ] || [ ! -d "${CLI_SRC}" ]; then
    skip "TEST 8: agent or cli source worktree not found — cannot exercise the unresolvable-pin fixture"
else
    STAGE8="${W}/stage8"
    make_stage "${STAGE8}" "cli"
    EXTRACT8="${W}/fn8.sh"
    extract_register_staged "${EXTRACT8}"

    # The extracted function alone (no set -e) would tolerate the failure and
    # keep going, exactly like the swallow bug did — so this invocation adds
    # `set -euo pipefail` explicitly, matching release.sh's own top-of-script
    # setting, to prove register_staged aborts the CALLER under the real
    # error-propagation contract, not just under a lenient test harness.
    set +e
    RESULT8="$(
        env \
        "${GO_ENV[@]}" \
        DRY_RUN=1 \
        RELEASE_REPO="${RELEASE_REPO}" \
        SHA256="${SHA256}" \
        bash -c "
            set -euo pipefail
            TARGETS=(\"darwin arm64\" \"darwin amd64\" \"linux arm64\" \"linux amd64\")
            # bins_for() lives earlier in release.sh, outside what
            # extract_register_staged pulls out — stub it (real cli value)
            # so THIS test isolates the updater_version failure path, not an
            # unrelated harness gap surfaced only because set -e is on here.
            bins_for() { printf '%s' 'burrowee-cli burrowee-cli-updater'; }
            . '${EXTRACT8}'
            register_staged cli v0.1.0.2026.06.17.badpin 0.1.0 '${STAGE8}' '${AGENT_SRC}' cli/v0.1.0.2026.06.17.badpin
        " 2>&1
    )"
    RC8=$?
    set -e

    [ "${RC8}" -ne 0 ] \
        || die "TEST 8: expected register_staged to FAIL (non-zero exit) for an unresolvable core/updater pin, got exit 0. Output:\n${RESULT8}"
    printf '%s\n' "${RESULT8}" | grep -q 'cannot resolve core/updater pin' \
        || die "TEST 8: expected a clear stderr diagnostic naming the unresolvable pin. Output:\n${RESULT8}"
    if printf '%s\n' "${RESULT8}" | grep -q 'would register'; then
        die "TEST 8: register_staged printed a dry-run preview despite an unresolvable pin — it must abort BEFORE building the body. Output:\n${RESULT8}"
    fi
    if printf '%s\n' "${RESULT8}" | grep -q '"updater_version":""'; then
        die "TEST 8: register_staged silently emitted an empty updater_version instead of failing. Output:\n${RESULT8}"
    fi

    echo "✓ TEST 8 PASSED — unresolvable core/updater pin aborts loudly (exit ${RC8}), no silent empty updater_version"
fi

# =============================================================================
echo ""
echo "✓ ALL TESTS PASSED"

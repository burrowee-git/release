#!/usr/bin/env bash
# payload.test.sh — unit tests for tools/payload.sh.
#
# Exercises the predicates directly (no release cut, no network, no builds).
# The zip cases build real archives with the real `zip` invocations release.sh
# uses, because the defect these guard against was `zip -j` silently dropping a
# directory — a mocked archiver would have "passed" the release that shipped
# broken.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HERE}/payload.sh"

fail=0
check() { # check <label> <got> <want>
    if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 — got '$2' want '$3'"; fail=1; fi
}
ok()   { echo "ok: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# --- fixtures ---------------------------------------------------------------
# write_ledger <dir> <row...> — a runner with a MIGRATIONS= ledger holding the
# given "<version> <script>" rows.
write_ledger() {
    local dir="$1"; shift
    mkdir -p "${dir}/migrations"
    { echo '#!/bin/sh'
      echo '# a comment mentioning MIGRATIONS=" that must not be parsed as the ledger'
      echo 'MIGRATIONS="'
      local row
      for row in "$@"; do echo "${row}"; done
      echo '"'
    } > "${dir}/migrations/run.sh"
}

# gateway_src <name> <script...> — a gateway source tree whose ledger names
# v1_to_v2.sh and whose migrations/ holds the given scripts (run.sh always).
gateway_src() {
    local dir="${TMP}/$1"; shift
    write_ledger "${dir}" "0.2.0 v1_to_v2.sh"
    local s
    for s in "$@"; do : > "${dir}/migrations/${s}"; done
    printf '%s' "${dir}"
}

# --- payload_file_extras / payload_dir_extras -------------------------------
check "file extras: gateway" "$(payload_file_extras gateway | paste -sd, -)" "update.sh"
check "file extras: cli"     "$(payload_file_extras cli     | paste -sd, -)" "update.sh"
check "file extras: edge"    "$(payload_file_extras edge    | paste -sd, -)" "update.sh,updater.update.sh"
check "file extras: relay"   "$(payload_file_extras relay   | paste -sd, -)" "update.sh,updater.update.sh"
check "file extras: agent"   "$(payload_file_extras agent   | paste -sd, -)" ""

# The gateway carries a DIRECTORY member. This is the assertion that would have
# caught the v0.2.0 cut: without a dir-extras entry, release.sh's zip -j pass is
# the only one that runs and the directory is dropped.
check "dir extras: gateway"  "$(payload_dir_extras gateway | paste -sd, -)" "migrations"
check "dir extras: edge"     "$(payload_dir_extras edge    | paste -sd, -)" "covers"
check "dir extras: cli"      "$(payload_dir_extras cli     | paste -sd, -)" ""
check "dir extras: agent"    "$(payload_dir_extras agent   | paste -sd, -)" ""

# --- payload_manifest -------------------------------------------------------
SRC="$(gateway_src manifest-gw v1_to_v2.sh)"
check "manifest: gateway" "$(payload_manifest gateway "${SRC}" | paste -sd, -)" \
    "update.sh,migrations/run.sh,migrations/v1_to_v2.sh"

# Discovery, not declaration: a migration added to the gateway repo appears with
# no edit to payload.sh.
: > "${SRC}/migrations/v2_to_v3.sh"
check "manifest: picks up a new migration" "$(payload_manifest gateway "${SRC}" | paste -sd, -)" \
    "update.sh,migrations/run.sh,migrations/v1_to_v2.sh,migrations/v2_to_v3.sh"

check "manifest: edge"  "$(payload_manifest edge  "${TMP}/nope" | paste -sd, -)" \
    "update.sh,updater.update.sh,covers/admin.html,covers/default.html"
check "manifest: agent" "$(payload_manifest agent "${TMP}/nope" | paste -sd, -)" ""

# --- stage_payload_extras ---------------------------------------------------
# comp_src <name> <file...> — a component source tree holding the given files.
comp_src() {
    local dir="${TMP}/$1"; shift
    mkdir -p "${dir}"
    local f
    for f in "$@"; do printf '%s\n' "${f}" > "${dir}/${f}"; done
    printf '%s' "${dir}"
}

# staged <dir> — the staged bundle's members, comma-joined, sorted.
staged() { ( cd "$1" && find . -type f | sed 's|^\./||' | sort | paste -sd, - ); }

# relay is the reason this function exists: its assembly site in release.sh used
# to open-code `install.sh update.sh updater.update.sh`, so it was the one
# component whose payload contents were still stated twice. Staging must produce
# the extras and NOT install.sh — whose provenance differs per component and so
# stays with the caller.
RELAY_SRC="$(comp_src relay-src install.sh update.sh updater.update.sh)"
RELAY_ASM="${TMP}/relay-asm"; mkdir -p "${RELAY_ASM}"
if stage_payload_extras relay "${RELAY_SRC}" "${RELAY_ASM}"; then
    ok "stage extras: relay succeeds"
else bad "stage extras: relay failed"; fi
check "stage extras: relay stages the manifest, not install.sh" \
    "$(staged "${RELAY_ASM}")" "update.sh,updater.update.sh"
if [ -x "${RELAY_ASM}/update.sh" ] && [ -x "${RELAY_ASM}/updater.update.sh" ]; then
    ok "stage extras: relay extras are executable"
else bad "stage extras: relay extras not executable"; fi
check "stage extras: relay copies content verbatim" \
    "$(cat "${RELAY_ASM}/updater.update.sh")" "updater.update.sh"

GW_SRC="$(comp_src gw-extras-src install.sh update.sh)"
GW_ASM="${TMP}/gw-extras-asm"; mkdir -p "${GW_ASM}"
stage_payload_extras gateway "${GW_SRC}" "${GW_ASM}"
check "stage extras: gateway takes update.sh only" "$(staged "${GW_ASM}")" "update.sh"

AGENT_ASM="${TMP}/agent-asm"; mkdir -p "${AGENT_ASM}"
if stage_payload_extras agent "${TMP}/nope" "${AGENT_ASM}"; then
    ok "stage extras: agent (no extras) succeeds without a source tree"
else bad "stage extras: agent failed"; fi
check "stage extras: agent stages nothing" "$(staged "${AGENT_ASM}")" ""

# Fail closed. A relay source missing updater.update.sh must stop the cut: the
# payload would extract and verify, then die on "cannot open ./updater.update.sh"
# at self-update time — on the operator's node, not here.
PARTIAL_SRC="$(comp_src relay-partial-src install.sh update.sh)"
PARTIAL_ASM="${TMP}/relay-partial-asm"; mkdir -p "${PARTIAL_ASM}"
if stage_payload_extras relay "${PARTIAL_SRC}" "${PARTIAL_ASM}" 2>/dev/null; then
    bad "stage extras: accepted a source missing a declared extra"
else ok "stage extras: rejects a source missing a declared extra"; fi

# --- ledger_migrations ------------------------------------------------------
write_ledger "${TMP}/ledger-one" "0.2.0 v1_to_v2.sh"
check "ledger: one row" "$(ledger_migrations "${TMP}/ledger-one/migrations/run.sh" | paste -sd, -)" "v1_to_v2.sh"

write_ledger "${TMP}/ledger-many" "0.2.0 v1_to_v2.sh" "0.2.5 v2_to_v3.sh" "0.3.0 v3_to_v4.sh"
check "ledger: ledger order preserved" \
    "$(ledger_migrations "${TMP}/ledger-many/migrations/run.sh" | paste -sd, -)" \
    "v1_to_v2.sh,v2_to_v3.sh,v3_to_v4.sh"

write_ledger "${TMP}/ledger-empty"
check "ledger: empty ledger" "$(ledger_migrations "${TMP}/ledger-empty/migrations/run.sh" | paste -sd, -)" ""

# An odd word count means a row lost its script (or its version) — refusing to
# guess which is the whole point.
write_ledger "${TMP}/ledger-odd" "0.2.0 v1_to_v2.sh" "0.2.5"
if ledger_migrations "${TMP}/ledger-odd/migrations/run.sh" >/dev/null 2>&1; then
    bad "ledger: odd word count accepted"
else ok "ledger: odd word count rejected"; fi

printf '#!/bin/sh\necho no ledger here\n' > "${TMP}/no-ledger.sh"
if ledger_migrations "${TMP}/no-ledger.sh" >/dev/null 2>&1; then
    bad "ledger: file with no MIGRATIONS= accepted"
else ok "ledger: file with no MIGRATIONS= rejected"; fi

{ echo 'MIGRATIONS="'; echo '0.2.0 v1_to_v2.sh'; echo '"'; echo 'MIGRATIONS="'; echo '0.3.0 x.sh'; echo '"'; } \
    > "${TMP}/two-ledgers.sh"
if ledger_migrations "${TMP}/two-ledgers.sh" >/dev/null 2>&1; then
    bad "ledger: two MIGRATIONS= assignments accepted"
else ok "ledger: two MIGRATIONS= assignments rejected"; fi

{ echo 'MIGRATIONS="'; echo '0.2.0 v1_to_v2.sh'; } > "${TMP}/unterminated.sh"
if ledger_migrations "${TMP}/unterminated.sh" >/dev/null 2>&1; then
    bad "ledger: unterminated assignment accepted"
else ok "ledger: unterminated assignment rejected"; fi

# --- stage_gateway_migrations -----------------------------------------------
SRC="$(gateway_src stage-gw v1_to_v2.sh)"
ASM="${TMP}/stage-asm"; mkdir -p "${ASM}"
if stage_gateway_migrations "${SRC}" "${ASM}"; then ok "stage: succeeds"; else bad "stage: failed"; fi
check "stage: copies every migration" \
    "$(cd "${ASM}" && find migrations -type f | sort | paste -sd, -)" \
    "migrations/run.sh,migrations/v1_to_v2.sh"
if [ -x "${ASM}/migrations/run.sh" ]; then ok "stage: runner is executable"; else bad "stage: runner not executable"; fi

mkdir -p "${TMP}/empty-gw/migrations" "${TMP}/empty-asm"
if stage_gateway_migrations "${TMP}/empty-gw" "${TMP}/empty-asm" 2>/dev/null; then
    bad "stage: empty migrations/ accepted"
else ok "stage: empty migrations/ rejected"; fi

# --- assert_payload_migrations ----------------------------------------------
# Build the payload the way release.sh does, with the real zip calls.
# pack <asset> <assemble-dir> <recurse:yes|no>
pack() {
    local asset="$1" asm="$2" recurse="$3"
    rm -f "${asset}"
    ( cd "${asm}" && zip -j -q "${asset}" ./* )
    if [ "${recurse}" = yes ]; then
        ( cd "${asm}" && zip -r -q "${asset}" migrations/ )
    fi
}

SRC="$(gateway_src zip-gw v1_to_v2.sh)"
ASM="${TMP}/zip-asm"; mkdir -p "${ASM}"
: > "${ASM}/burrowee-gateway"; : > "${ASM}/install.sh"; : > "${ASM}/update.sh"
stage_gateway_migrations "${SRC}" "${ASM}" >/dev/null

# The regression itself: zip -j alone drops migrations/ entirely.
pack "${TMP}/junked.zip" "${ASM}" no
check "zip -j alone drops migrations/" \
    "$(unzip -Z1 "${TMP}/junked.zip" | grep -c '^migrations/')" "0"
if assert_payload_migrations gateway "${TMP}/junked.zip" "${SRC}" 2>/dev/null; then
    bad "gate: accepted a payload with no migrations/run.sh"
else ok "gate: rejects a payload with no migrations/run.sh"; fi

# With the recursive pass the paths survive and the gate passes.
pack "${TMP}/good.zip" "${ASM}" yes
# (zip -r also records a bare "migrations/" directory entry; only the files matter)
check "zip -r keeps the migrations/ path" \
    "$(unzip -Z1 "${TMP}/good.zip" | grep '^migrations/' | grep -v '/$' | sort | paste -sd, -)" \
    "migrations/run.sh,migrations/v1_to_v2.sh"
if assert_payload_migrations gateway "${TMP}/good.zip" "${SRC}"; then
    ok "gate: accepts a complete payload"
else bad "gate: rejected a complete payload"; fi

# A ledger row whose script never made it into the zip: the subtler failure, and
# an unrecoverable one downstream (the runner skips it and the version is
# recorded anyway).
LEDGER_SRC="$(gateway_src ledger-gap-gw v1_to_v2.sh)"
LEDGER_ASM="${TMP}/ledger-gap-asm"; mkdir -p "${LEDGER_ASM}"
: > "${LEDGER_ASM}/install.sh"
stage_gateway_migrations "${LEDGER_SRC}" "${LEDGER_ASM}" >/dev/null
rm "${LEDGER_ASM}/migrations/v1_to_v2.sh"
pack "${TMP}/ledger-gap.zip" "${LEDGER_ASM}" yes
if assert_payload_migrations gateway "${TMP}/ledger-gap.zip" "${LEDGER_SRC}" 2>/dev/null; then
    bad "gate: accepted a payload missing a ledger-named migration"
else ok "gate: rejects a payload missing a ledger-named migration"; fi

# Non-gateway components are untouched by the gate.
if assert_payload_migrations edge "${TMP}/junked.zip" "${SRC}"; then
    ok "gate: no-op for edge"
else bad "gate: fired on a non-gateway component"; fi

if [ "${fail}" = 0 ]; then echo "ALL OK"; else echo "TESTS FAILED"; exit 1; fi

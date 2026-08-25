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
# v0_1_to_v0_2.sh and whose migrations/ holds the given scripts (run.sh always).
gateway_src() {
    local dir="${TMP}/$1"; shift
    write_ledger "${dir}" "0.2.0 v0_1_to_v0_2.sh"
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
# edge, cli and relay carry migrations/ too since they took the SHARED ladder —
# same reasoning: without a dir-extras entry only the zip -j pass runs and the
# directory is silently dropped, which is how a gateway shipped without one.
check "dir extras: edge"     "$(payload_dir_extras edge    | paste -sd, -)" "covers,migrations"
check "dir extras: cli"      "$(payload_dir_extras cli     | paste -sd, -)" "migrations"
check "dir extras: relay"    "$(payload_dir_extras relay   | paste -sd, -)" "migrations"
check "dir extras: agent"    "$(payload_dir_extras agent   | paste -sd, -)" ""

# --- payload_manifest -------------------------------------------------------
SRC="$(gateway_src manifest-gw v0_1_to_v0_2.sh)"
check "manifest: gateway" "$(payload_manifest gateway "${SRC}" | paste -sd, -)" \
    "update.sh,migrations/run.sh,migrations/v0_1_to_v0_2.sh"

# Discovery, not declaration: a migration added to the gateway repo appears with
# no edit to payload.sh.
: > "${SRC}/migrations/v2_to_v3.sh"
check "manifest: picks up a new migration" "$(payload_manifest gateway "${SRC}" | paste -sd, -)" \
    "update.sh,migrations/run.sh,migrations/v0_1_to_v0_2.sh,migrations/v2_to_v3.sh"

# …AND A NON-SCRIPT MEMBER TOO. The gateway's migrations/ holds only scripts
# today, which is the only reason a `*.sh` glob on the rkit side and a `*` glob
# here looked identical for so long. cmd/rkit/payload_manifest_test.go pins the
# two lists together; this states the shell side's own expectation.
: > "${SRC}/migrations/component.conf"
check "manifest: ships a non-script migrations member" "$(payload_manifest gateway "${SRC}" | paste -sd, -)" \
    "update.sh,migrations/component.conf,migrations/run.sh,migrations/v0_1_to_v0_2.sh,migrations/v2_to_v3.sh"

# edge's manifest carries the SHARED ladder's members plus its own two files.
# The shared half is discovered by glob from inner/_shared/migrations, so it is
# pinned here against a fixture rather than against the real directory — a test
# that globbed the same directory the code globs would agree with itself no
# matter what either contained.
SHARED_FIX="${TMP}/shared-migrations"
mkdir -p "${SHARED_FIX}"
: > "${SHARED_FIX}/run.sh"; : > "${SHARED_FIX}/upgrade.sh"; : > "${SHARED_FIX}/lib_paths.sh"
: > "${SHARED_FIX}/lib_stale_user_bins.sh"; : > "${SHARED_FIX}/stale_user_bins.sh"
: > "${SHARED_FIX}/adopt_user_tree.sh"
# A TEST SUITE IS NOT PAYLOAD. Both spellings go into the fixture and NEITHER
# may appear in any manifest below — the expectations that follow are unchanged
# by their presence, which is the assertion. adopt_updater_unit_test.sh really
# did sit in inner/_shared/migrations and really was staged, chmod 0755, into
# every edge, cli and relay zip; it now lives in tools/adopt_updater_unit.test.sh
# and cmd/rkit/assemble.go drops the same two patterns.
: > "${SHARED_FIX}/adopt_updater_unit.test.sh"
: > "${SHARED_FIX}/adopt_updater_unit_test.sh"
SHARED_MIGRATIONS_DIR="${SHARED_FIX}"
check "shared scripts: test suites are not staged" \
    "$(shared_migration_scripts | paste -sd, -)" \
    "adopt_user_tree.sh,lib_paths.sh,lib_stale_user_bins.sh,run.sh,stale_user_bins.sh,upgrade.sh"
EDGE_SRC="${TMP}/manifest-edge"
mkdir -p "${EDGE_SRC}/migrations"
: > "${EDGE_SRC}/migrations/component.conf"; : > "${EDGE_SRC}/migrations/ledger"
check "manifest: edge"  "$(payload_manifest edge  "${EDGE_SRC}" | paste -sd, -)" \
    "update.sh,updater.update.sh,covers/admin.html,covers/default.html,migrations/adopt_user_tree.sh,migrations/lib_paths.sh,migrations/lib_stale_user_bins.sh,migrations/run.sh,migrations/stale_user_bins.sh,migrations/upgrade.sh,migrations/component.conf,migrations/ledger"
check "manifest: cli"   "$(payload_manifest cli   "${EDGE_SRC}" | paste -sd, -)" \
    "update.sh,migrations/adopt_user_tree.sh,migrations/lib_paths.sh,migrations/lib_stale_user_bins.sh,migrations/run.sh,migrations/stale_user_bins.sh,migrations/upgrade.sh,migrations/component.conf,migrations/ledger"

# relay takes the shared ladder too (0.2.2 root-only collapse), contributing
# component.conf + ledger + its own unit-derived adoption rung.
RELAY_MIG_SRC="${TMP}/manifest-relay"
mkdir -p "${RELAY_MIG_SRC}/migrations"
: > "${RELAY_MIG_SRC}/migrations/component.conf"
printf '0.2.2 stale_user_bins.sh\n0.2.2 adopt_unit_home_tree.sh\n' > "${RELAY_MIG_SRC}/migrations/ledger"
: > "${RELAY_MIG_SRC}/migrations/adopt_unit_home_tree.sh"
check "manifest: relay" "$(payload_manifest relay "${RELAY_MIG_SRC}" | paste -sd, -)" \
    "update.sh,updater.update.sh,migrations/adopt_user_tree.sh,migrations/lib_paths.sh,migrations/lib_stale_user_bins.sh,migrations/run.sh,migrations/stale_user_bins.sh,migrations/upgrade.sh,migrations/adopt_unit_home_tree.sh,migrations/component.conf,migrations/ledger"

# --- stage_component_migrations (shared ladder) -----------------------------
SHARED_ASM="${TMP}/shared-asm"; mkdir -p "${SHARED_ASM}"
if stage_component_migrations cli "${EDGE_SRC}" "${SHARED_ASM}"; then
    ok "shared stage: succeeds"
else bad "shared stage: failed"; fi
for f in run.sh upgrade.sh lib_paths.sh lib_stale_user_bins.sh stale_user_bins.sh adopt_user_tree.sh component.conf ledger; do
    if [ -f "${SHARED_ASM}/migrations/${f}" ]; then ok "shared stage: ${f}"
    else bad "shared stage: ${f} missing"; fi
done

# component.conf and ledger are REQUIRED, because the shared runner carries no
# component defaults: a kit without them refuses on EVERY install, and the cut
# is the last place that is cheap to find out.
NOCONF_SRC="${TMP}/manifest-noconf"; mkdir -p "${NOCONF_SRC}/migrations"
: > "${NOCONF_SRC}/migrations/ledger"
if stage_component_migrations cli "${NOCONF_SRC}" "${TMP}/noconf-asm" 2>/dev/null; then
    bad "shared stage: accepted a source with no component.conf"
else ok "shared stage: rejects a source with no component.conf"; fi

# --- ledger_file_migrations -------------------------------------------------
printf '# a comment\n\n0.2.0 stale_user_bins.sh\n0.3.0 rekey.sh\n' > "${TMP}/ledger.ok"
check "ledger file: rows" "$(ledger_file_migrations "${TMP}/ledger.ok" | paste -sd, -)" \
    "stale_user_bins.sh,rekey.sh"
printf '0.2.0 stale_user_bins.sh\n0.3.0\n' > "${TMP}/ledger.odd"
if ledger_file_migrations "${TMP}/ledger.odd" >/dev/null 2>&1; then
    bad "ledger file: accepted a dangling row"
else ok "ledger file: rejects a dangling row"; fi
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
# the extras — since 0.2.2 the shared ladder plus relay's own half among them —
# and NOT install.sh, whose provenance differs per component and so stays with
# the caller.
RELAY_SRC="$(comp_src relay-src install.sh update.sh updater.update.sh)"
mkdir -p "${RELAY_SRC}/migrations"
: > "${RELAY_SRC}/migrations/component.conf"
printf '0.2.2 stale_user_bins.sh\n0.2.2 adopt_unit_home_tree.sh\n' > "${RELAY_SRC}/migrations/ledger"
: > "${RELAY_SRC}/migrations/adopt_unit_home_tree.sh"
RELAY_ASM="${TMP}/relay-asm"; mkdir -p "${RELAY_ASM}"
if stage_payload_extras relay "${RELAY_SRC}" "${RELAY_ASM}"; then
    ok "stage extras: relay succeeds"
else bad "stage extras: relay failed"; fi
check "stage extras: relay stages the manifest, not install.sh" \
    "$(staged "${RELAY_ASM}")" \
    "migrations/adopt_unit_home_tree.sh,migrations/adopt_user_tree.sh,migrations/component.conf,migrations/ledger,migrations/lib_paths.sh,migrations/lib_stale_user_bins.sh,migrations/run.sh,migrations/stale_user_bins.sh,migrations/upgrade.sh,update.sh,updater.update.sh"
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
write_ledger "${TMP}/ledger-one" "0.2.0 v0_1_to_v0_2.sh"
check "ledger: one row" "$(ledger_migrations "${TMP}/ledger-one/migrations/run.sh" | paste -sd, -)" "v0_1_to_v0_2.sh"

write_ledger "${TMP}/ledger-many" "0.2.0 v0_1_to_v0_2.sh" "0.2.5 v2_to_v3.sh" "0.3.0 v3_to_v4.sh"
check "ledger: ledger order preserved" \
    "$(ledger_migrations "${TMP}/ledger-many/migrations/run.sh" | paste -sd, -)" \
    "v0_1_to_v0_2.sh,v2_to_v3.sh,v3_to_v4.sh"

write_ledger "${TMP}/ledger-empty"
check "ledger: empty ledger" "$(ledger_migrations "${TMP}/ledger-empty/migrations/run.sh" | paste -sd, -)" ""

# An odd word count means a row lost its script (or its version) — refusing to
# guess which is the whole point.
write_ledger "${TMP}/ledger-odd" "0.2.0 v0_1_to_v0_2.sh" "0.2.5"
if ledger_migrations "${TMP}/ledger-odd/migrations/run.sh" >/dev/null 2>&1; then
    bad "ledger: odd word count accepted"
else ok "ledger: odd word count rejected"; fi

printf '#!/bin/sh\necho no ledger here\n' > "${TMP}/no-ledger.sh"
if ledger_migrations "${TMP}/no-ledger.sh" >/dev/null 2>&1; then
    bad "ledger: file with no MIGRATIONS= accepted"
else ok "ledger: file with no MIGRATIONS= rejected"; fi

{ echo 'MIGRATIONS="'; echo '0.2.0 v0_1_to_v0_2.sh'; echo '"'; echo 'MIGRATIONS="'; echo '0.3.0 x.sh'; echo '"'; } \
    > "${TMP}/two-ledgers.sh"
if ledger_migrations "${TMP}/two-ledgers.sh" >/dev/null 2>&1; then
    bad "ledger: two MIGRATIONS= assignments accepted"
else ok "ledger: two MIGRATIONS= assignments rejected"; fi

{ echo 'MIGRATIONS="'; echo '0.2.0 v0_1_to_v0_2.sh'; } > "${TMP}/unterminated.sh"
if ledger_migrations "${TMP}/unterminated.sh" >/dev/null 2>&1; then
    bad "ledger: unterminated assignment accepted"
else ok "ledger: unterminated assignment rejected"; fi

# --- stage_gateway_migrations -----------------------------------------------
SRC="$(gateway_src stage-gw v0_1_to_v0_2.sh)"
ASM="${TMP}/stage-asm"; mkdir -p "${ASM}"
if stage_gateway_migrations "${SRC}" "${ASM}"; then ok "stage: succeeds"; else bad "stage: failed"; fi
check "stage: copies every migration" \
    "$(cd "${ASM}" && find migrations -type f | sort | paste -sd, -)" \
    "migrations/run.sh,migrations/v0_1_to_v0_2.sh"
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

SRC="$(gateway_src zip-gw v0_1_to_v0_2.sh lib_stale_user_bins.sh)"
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
    "migrations/lib_stale_user_bins.sh,migrations/run.sh,migrations/v0_1_to_v0_2.sh"
if assert_payload_migrations gateway "${TMP}/good.zip" "${SRC}"; then
    ok "gate: accepts a complete payload"
else bad "gate: rejected a complete payload"; fi

# THE SWEEP LIBRARY IS NOT A LEDGER ROW, so the ledger check below can never ask
# for it — and install.sh SOURCES it. A zip without it installs cleanly and
# silently stops removing the per-user copies that shadow /usr/local/bin on
# PATH, which is the defect that made the sweep a ladder rung in the first
# place. Its own assertion, or nothing asserts it at all.
NOLIB_ASM="${TMP}/nolib-asm"; mkdir -p "${NOLIB_ASM}"
: > "${NOLIB_ASM}/install.sh"
stage_gateway_migrations "${SRC}" "${NOLIB_ASM}" >/dev/null
rm "${NOLIB_ASM}/migrations/lib_stale_user_bins.sh"
pack "${TMP}/nolib.zip" "${NOLIB_ASM}" yes
if assert_payload_migrations gateway "${TMP}/nolib.zip" "${SRC}" 2>/dev/null; then
    bad "gate: accepted a payload with no stale-user-bin sweep library"
else ok "gate: rejects a payload with no stale-user-bin sweep library"; fi

# A ledger row whose script never made it into the zip: the subtler failure, and
# an unrecoverable one downstream (the runner skips it and the version is
# recorded anyway).
LEDGER_SRC="$(gateway_src ledger-gap-gw v0_1_to_v0_2.sh lib_stale_user_bins.sh)"
LEDGER_ASM="${TMP}/ledger-gap-asm"; mkdir -p "${LEDGER_ASM}"
: > "${LEDGER_ASM}/install.sh"
stage_gateway_migrations "${LEDGER_SRC}" "${LEDGER_ASM}" >/dev/null
rm "${LEDGER_ASM}/migrations/v0_1_to_v0_2.sh"
pack "${TMP}/ledger-gap.zip" "${LEDGER_ASM}" yes
if assert_payload_migrations gateway "${TMP}/ledger-gap.zip" "${LEDGER_SRC}" 2>/dev/null; then
    bad "gate: accepted a payload missing a ledger-named migration"
else ok "gate: rejects a payload missing a ledger-named migration"; fi

# Components with NO ladder at all are untouched by the gate.
if assert_payload_migrations agent "${TMP}/junked.zip" "${SRC}"; then
    ok "gate: no-op for a component with no ladder"
else bad "gate: fired on a component with no ladder"; fi

# --- the gate on a SHARED-ladder component ----------------------------------
# A zip whose migrations/ was dropped by `zip -j` must be refused for edge and
# cli exactly as it is for the gateway: install.sh sources the sweep and runs
# the ladder out of that directory.
if assert_payload_migrations edge "${TMP}/junked.zip" "${EDGE_SRC}" 2>/dev/null; then
    bad "gate: accepted a shared-ladder payload with no migrations/"
else ok "gate: rejects a shared-ladder payload with no migrations/"; fi

SHARED_ZIP_ASM="${TMP}/shared-zip"; mkdir -p "${SHARED_ZIP_ASM}"
stage_component_migrations edge "${EDGE_SRC}" "${SHARED_ZIP_ASM}" >/dev/null
printf '0.2.0 stale_user_bins.sh\n' > "${EDGE_SRC}/migrations/ledger"
cp "${EDGE_SRC}/migrations/ledger" "${SHARED_ZIP_ASM}/migrations/ledger"
( cd "${SHARED_ZIP_ASM}" && zip -r -q "${TMP}/shared-good.zip" migrations/ )
if assert_payload_migrations edge "${TMP}/shared-good.zip" "${EDGE_SRC}"; then
    ok "gate: accepts a complete shared-ladder payload"
else bad "gate: rejected a complete shared-ladder payload"; fi

# …and refuses when the LEDGER names a rung the zip does not carry — the row
# the runner would refuse on, on every host, after the cut.
rm -f "${SHARED_ZIP_ASM}/migrations/stale_user_bins.sh"
rm -f "${TMP}/shared-gap.zip"
( cd "${SHARED_ZIP_ASM}" && zip -r -q "${TMP}/shared-gap.zip" migrations/ )
if assert_payload_migrations edge "${TMP}/shared-gap.zip" "${EDGE_SRC}" 2>/dev/null; then
    bad "gate: accepted a shared-ladder payload missing a ledger-named rung"
else ok "gate: rejects a shared-ladder payload missing a ledger-named rung"; fi

# --- the gate on relay --------------------------------------------------------
# relay is gated like the other shared-ladder components, plus one member of its
# own: migrations/adopt_user_tree.sh, the shared rung its ledger-named
# adopt_unit_home_tree.sh DELEGATES to. No ledger row names it, so without its
# own assertion nothing would ever ask for it — the same reasoning as the sweep
# library for the gateway.
if assert_payload_migrations relay "${TMP}/junked.zip" "${RELAY_MIG_SRC}" 2>/dev/null; then
    bad "gate: accepted a relay payload with no migrations/"
else ok "gate: rejects a relay payload with no migrations/"; fi

RELAY_ZIP_ASM="${TMP}/relay-zip"; mkdir -p "${RELAY_ZIP_ASM}"
stage_component_migrations relay "${RELAY_MIG_SRC}" "${RELAY_ZIP_ASM}" >/dev/null
( cd "${RELAY_ZIP_ASM}" && zip -r -q "${TMP}/relay-good.zip" migrations/ )
if assert_payload_migrations relay "${TMP}/relay-good.zip" "${RELAY_MIG_SRC}"; then
    ok "gate: accepts a complete relay payload"
else bad "gate: rejected a complete relay payload"; fi

# The delegation target missing is refused for relay — and ONLY for relay: the
# other shared-ladder components' ladders do not hard-depend on it, so the
# requirement stays scoped to the kit that would break.
rm -f "${RELAY_ZIP_ASM}/migrations/adopt_user_tree.sh" "${TMP}/relay-noadopt.zip"
( cd "${RELAY_ZIP_ASM}" && zip -r -q "${TMP}/relay-noadopt.zip" migrations/ )
if assert_payload_migrations relay "${TMP}/relay-noadopt.zip" "${RELAY_MIG_SRC}" 2>/dev/null; then
    bad "gate: accepted a relay payload with no shared adoption rung"
else ok "gate: rejects a relay payload with no shared adoption rung"; fi
# The SAME zip is fine for edge, whose ladder does not delegate to it.
if assert_payload_migrations edge "${TMP}/relay-noadopt.zip" "${EDGE_SRC}"; then
    ok "gate: adopt_user_tree.sh requirement stays relay-scoped"
else bad "gate: adopt_user_tree.sh requirement leaked beyond relay"; fi

# …and the row check itself: relay's OWN rung named in the ledger but not in
# the zip is refused, same as any other ledger gap.
cp "${SHARED_FIX}/adopt_user_tree.sh" "${RELAY_ZIP_ASM}/migrations/adopt_user_tree.sh"
rm -f "${RELAY_ZIP_ASM}/migrations/adopt_unit_home_tree.sh" "${TMP}/relay-norung.zip"
( cd "${RELAY_ZIP_ASM}" && zip -r -q "${TMP}/relay-norung.zip" migrations/ )
if assert_payload_migrations relay "${TMP}/relay-norung.zip" "${RELAY_MIG_SRC}" 2>/dev/null; then
    bad "gate: accepted a relay payload missing its ledger-named adoption rung"
else ok "gate: rejects a relay payload missing its ledger-named adoption rung"; fi

# --- the gate on the UPDATER LEDGER (edge/gateway/relay only) ---------------
# migrations/updater-ledger is a SECOND, SEPARATE ledger for the updater's own
# track (Task 10, elsewhere: edge, gateway, relay — cli and agent have no
# updater). No component in this repo's own fixtures ships one yet, so absence
# is a no-op; the check fires the moment a source carries one.

# No updater-ledger in EDGE_SRC: the gate stayed silent about it in the
# "accepts a complete shared-ladder payload" case above. Asserted directly too.
if assert_updater_ledger edge "${EDGE_SRC}" "${TMP}/shared-good.zip" "$(unzip -Z1 "${TMP}/shared-good.zip")"; then
    ok "gate: no updater-ledger in source is a no-op"
else bad "gate: fired with no updater-ledger in source"; fi

UL_SRC="${TMP}/updater-ledger-edge"
mkdir -p "${UL_SRC}/migrations"
: > "${UL_SRC}/migrations/component.conf"
printf '0.2.0 stale_user_bins.sh\n' > "${UL_SRC}/migrations/ledger"
printf '# updater track\n0.2.0 adopt_updater_unit.sh\n' > "${UL_SRC}/migrations/updater-ledger"

# stage_component_migrations copies updater-ledger too — it is just another
# file under the component's own migrations/, discovered by the same glob as
# component.conf and ledger. adopt_updater_unit.sh itself is normally staged
# from inner/_shared/migrations (SHARED_MIGRATIONS_DIR), which this suite
# points at a fixture (SHARED_FIX) that predates this rung; added here by hand
# rather than widening SHARED_FIX and re-pinning every manifest string above
# that already asserts its exact sorted contents.
UL_ASM="${TMP}/updater-ledger-asm"; mkdir -p "${UL_ASM}"
stage_component_migrations edge "${UL_SRC}" "${UL_ASM}" >/dev/null
: > "${UL_ASM}/migrations/adopt_updater_unit.sh"
( cd "${UL_ASM}" && zip -r -q "${TMP}/updater-ledger-good.zip" migrations/ )
if assert_payload_migrations edge "${TMP}/updater-ledger-good.zip" "${UL_SRC}"; then
    ok "gate: accepts a payload whose updater-ledger row is present"
else bad "gate: rejected a payload whose updater-ledger row is present"; fi

# updater-ledger exists in source but was never staged into the zip — the
# "row check" reasoning applied one level up, to the ledger file itself.
UL_ASM2="${TMP}/updater-ledger-asm2"; mkdir -p "${UL_ASM2}"
stage_component_migrations edge "${UL_SRC}" "${UL_ASM2}" >/dev/null
: > "${UL_ASM2}/migrations/adopt_updater_unit.sh"
rm -f "${UL_ASM2}/migrations/updater-ledger"
( cd "${UL_ASM2}" && zip -r -q "${TMP}/updater-ledger-notstaged.zip" migrations/ )
if assert_payload_migrations edge "${TMP}/updater-ledger-notstaged.zip" "${UL_SRC}" 2>/dev/null; then
    bad "gate: accepted a payload with updater-ledger in source but not in the zip"
else ok "gate: rejects a payload with updater-ledger in source but not in the zip"; fi

# updater-ledger staged, but the rung it NAMES is missing from the zip — a row
# the updater's run.sh would refuse on, on every host, after the cut.
UL_ASM3="${TMP}/updater-ledger-asm3"; mkdir -p "${UL_ASM3}"
stage_component_migrations edge "${UL_SRC}" "${UL_ASM3}" >/dev/null
( cd "${UL_ASM3}" && zip -r -q "${TMP}/updater-ledger-gap.zip" migrations/ )
if assert_payload_migrations edge "${TMP}/updater-ledger-gap.zip" "${UL_SRC}" 2>/dev/null; then
    bad "gate: accepted a payload missing its updater-ledger-named rung"
else ok "gate: rejects a payload missing its updater-ledger-named rung"; fi

# cli takes the shared ladder but has no updater — an updater-ledger in its
# source (however unlikely) must never be checked; the requirement stays
# scoped to edge/gateway/relay, same reasoning as relay's own adopt-rung check.
CLI_UL_SRC="${TMP}/updater-ledger-cli"
mkdir -p "${CLI_UL_SRC}/migrations"
: > "${CLI_UL_SRC}/migrations/component.conf"
printf '0.2.0 stale_user_bins.sh\n' > "${CLI_UL_SRC}/migrations/ledger"
printf '0.2.0 adopt_updater_unit.sh\n' > "${CLI_UL_SRC}/migrations/updater-ledger"
CLI_UL_ASM="${TMP}/updater-ledger-cli-asm"; mkdir -p "${CLI_UL_ASM}"
stage_component_migrations cli "${CLI_UL_SRC}" "${CLI_UL_ASM}" >/dev/null
# deliberately NOT staging adopt_updater_unit.sh — if the cli exemption ever
# regressed, this zip would fail the row check and this case would catch it.
( cd "${CLI_UL_ASM}" && zip -r -q "${TMP}/updater-ledger-cli.zip" migrations/ )
if assert_payload_migrations cli "${TMP}/updater-ledger-cli.zip" "${CLI_UL_SRC}"; then
    ok "gate: updater-ledger check stays scoped to edge/gateway/relay (cli exempt)"
else bad "gate: updater-ledger check leaked to cli"; fi

# gateway takes the updater-ledger check too, through the NON-shared-ladder tail
# of assert_payload_migrations — its own runner/ledger shape, exercised earlier.
#
# stage_gateway_migrations now globs migrations/* (Task 10's staging fix,
# tools/payload.sh lines ~170/252) rather than migrations/*.sh — gateway's own
# ledger has always lived INSIDE run.sh (see ledger_migrations above), so its
# migrations/ never held a plain data file before updater-ledger. No manual cp
# here: this proves the STAGING path actually carries the data file into the
# zip, not just the assertion's own logic in isolation.
GW_UL_SRC="$(gateway_src updater-ledger-gw v0_1_to_v0_2.sh lib_stale_user_bins.sh)"
printf '0.2.0 adopt_updater_unit.sh\n' > "${GW_UL_SRC}/migrations/updater-ledger"
GW_UL_ASM="${TMP}/updater-ledger-gw-asm"; mkdir -p "${GW_UL_ASM}"
: > "${GW_UL_ASM}/install.sh"
stage_gateway_migrations "${GW_UL_SRC}" "${GW_UL_ASM}" >/dev/null
if [ -f "${GW_UL_ASM}/migrations/updater-ledger" ]; then
    ok "staging: gateway's *-glob fix carries migrations/updater-ledger (data file) into the assemble dir"
else bad "staging: gateway migrations/updater-ledger was NOT staged (glob still *.sh-only)"; fi
if [ ! -x "${GW_UL_ASM}/migrations/updater-ledger" ]; then
    ok "staging: gateway's staged updater-ledger is not executable (data file, not a script)"
else bad "staging: gateway's staged updater-ledger was wrongly made executable"; fi
( cd "${GW_UL_ASM}" && zip -r -q "${TMP}/updater-ledger-gw-gap.zip" migrations/ )
if assert_payload_migrations gateway "${TMP}/updater-ledger-gw-gap.zip" "${GW_UL_SRC}" 2>/dev/null; then
    bad "gate: accepted a gateway payload missing its updater-ledger-named rung"
else ok "gate: rejects a gateway payload missing its updater-ledger-named rung"; fi
: > "${GW_UL_ASM}/migrations/adopt_updater_unit.sh"
( cd "${GW_UL_ASM}" && zip -r -q "${TMP}/updater-ledger-gw-good.zip" migrations/ )
if assert_payload_migrations gateway "${TMP}/updater-ledger-gw-good.zip" "${GW_UL_SRC}"; then
    ok "gate: accepts a complete gateway payload with an updater-ledger row"
else bad "gate: rejected a complete gateway payload with an updater-ledger row"; fi

if [ "${fail}" = 0 ]; then echo "ALL OK"; else echo "TESTS FAILED"; exit 1; fi

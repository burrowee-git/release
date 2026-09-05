#!/usr/bin/env bash
# test-payload-assembly.sh — prove tools/release.sh's two assembly sites ship
# exactly the shared manifest, by running release.sh's OWN TEXT.
#
# WHY THIS FILE EXISTS
# cmd/rkit/payload_manifest_test.go pins tools/payload.sh's manifest to
# cmd/rkit/assemble.go's. Neither of those is what a cut actually runs: every
# release to date was assembled by tools/release.sh, and the gateway v0.2.0
# defect lived precisely in the gap between the manifest and that orchestrator's
# own open-coded copy of it. Two such copies survived the first fix — one per
# assembly site: do_release's `case` for update_scripts, and do_release_relay's
# `for s in install.sh update.sh updater.update.sh`, the latter kept because
# relay takes install.sh from its component source while the public components
# take theirs from inner/<comp>/install.sh.
#
# So this test does not re-state what a component carries and hope release.sh
# agrees. It EXTRACTS each assembly block from tools/release.sh, runs it over a
# fixture with stand-in binaries, and asserts the finished zip against:
#
#   1. a literal member list — the invariant, so mutating the manifest is caught
#      even though the assembly followed it faithfully; and
#   2. the manifest as computed at run time, with members INJECTED into it —
#      so re-open-coding a list in release.sh (the actual regression) shows up
#      as a member the manifest asked for and the zip does not have.
#
# It also asserts each member's PROVENANCE where two components differ (relay's
# install.sh from its own source, the public components' from inner/<comp>/,
# edge's covers from the edge.web tree), because provenance is the reason the
# relay site was left out of the manifest in the first place.
#
# No builds, no network, no keys: the binaries are files with known bytes,
# because what is under test is which members reach the archive, not what they
# contain.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HERE}/payload.sh"
# The channel table: the assembly block now names the dispatcher and resolves
# the inner installer through it, so the fixture has to be able to answer the
# same questions release.sh does rather than restate them.
# shellcheck source=tools/channels.sh
source "${HERE}/channels.sh"

fail=0
check() { # check <label> <got> <want>
    if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 — got '$2' want '$3'"; fail=1; fi
}
ok()  { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# The SHARED ladder half of a shared-ladder component's migrations/ is globbed
# from SHARED_MIGRATIONS_DIR. Pin it to a fixture mirroring the real
# inner/_shared/migrations file set, so the literal member lists below stay
# hermetic — a test that globbed the real directory would drift with it and
# assert nothing about what a kit carries.
SHARED_FIX="${TMP}/shared-migrations"
mkdir -p "${SHARED_FIX}"
for f in adopt_updater_unit.sh adopt_user_tree.sh lib_paths.sh lib_stale_user_bins.sh repoint_lan_cert.sh run.sh stale_user_bins.sh sweep_stale_exec_root.sh upgrade.sh; do
    printf '#!/bin/sh\n' > "${SHARED_FIX}/${f}"
done
# shellcheck disable=SC2034  # read by the sourced payload.sh staging functions.
SHARED_MIGRATIONS_DIR="${SHARED_FIX}"

# shared_ladder_src <src> — give a shared-ladder component's fixture source its
# OWN half of the ladder: component.conf + a ledger naming a rung the shared
# fixture really carries (assert_payload_migrations cross-checks the ledger
# against the finished zip).
shared_ladder_src() {
    mkdir -p "$1/migrations"
    printf 'COMP=x\n' > "$1/migrations/component.conf"
    printf '0.2.0 stale_user_bins.sh\n' > "$1/migrations/ledger"
}

# --- the code under test ------------------------------------------------------
# Each per-target assembly block: from the line that names the staging dir
# through the last line before the zip is recorded. Pulled out of the shipped
# file so this cannot drift from what an operator runs.
PUBLIC_ASSEMBLY="$(awk '/^do_release\(\) \{/,/^\}/' "${HERE}/release.sh" \
    | awk '/^        # assemble: component bins/,/^        zips\+=\(/' \
    | grep -v '^        zips+=(')"
RELAY_ASSEMBLY="$(awk '/^do_release_relay\(\) \{/,/^\}/' "${HERE}/release.sh" \
    | awk '/^        assemble="\$\{stage\}/,/^        zips\+=\(/' \
    | grep -v '^        zips+=(')"

# Extraction is by pattern, so a rename in release.sh could silently yield an
# empty block that "passes" every assertion below. Refuse that outright.
for pair in "public:${PUBLIC_ASSEMBLY}" "relay:${RELAY_ASSEMBLY}"; do
    if [ -z "${pair#*:}" ] || ! printf '%s\n' "${pair#*:}" | grep -q 'zip -j'; then
        echo "FAIL: could not extract the ${pair%%:*} assembly block from release.sh" >&2
        echo "      (the markers moved — fix this test's extraction, do not delete it)" >&2
        exit 1
    fi
done

# --- fixture ------------------------------------------------------------------
# shellcheck disable=SC2034  # every name here is read (or assigned) by the EVAL'd assembly blocks; shellcheck cannot see through eval.
{
    os=darwin
    arch=arm64
    # variant/plat: release.sh's do_release()/do_release_relay() compute
    # `plat` (via plat_of()) BEFORE the extracted assembly block starts —
    # out_bins is named from it too, one line earlier than the "# assemble:"
    # marker the extraction below anchors on — so the fixture (not the
    # extracted text) owns setting it, exactly like os/arch. Default is the
    # stock (no-variant) platform; the darwin-amd64-legacy case further down
    # overrides both before calling fixture().
    variant=""
    plat="darwin-arm64"
    APPLE_SIGN=""
    # Assigned by the blocks; declared so `set -u` is honest about what the
    # extracted code owns.
    comp=""
    bins=""
    # CHANNEL steers the fixture the way it steers a cut: which dispatcher name
    # the assembly copies, and which of inner/<comp>/{install.sh,beta.install.sh}
    # it stages. Default stable — the beta cases below set it and reset it.
    CHANNEL="stable"
    src=""
    out_bins=""
    DISP_DIR=""
    DISP_NAME=""
    stage=""
    REPO_ROOT=""
    EDGE_WEB=""
    assemble=""
    asset=""
    b=""
    d=""
}

# fixture <comp> <bin...> — a clean source tree, built-binary dir, dispatcher
# dir, stage dir and release-repo root for one component. The bins are files
# with known bytes: what is under test is membership, not content.
fixture() {
    comp="$1"; shift
    bins="$*"
    plat="${os}-${arch}${variant:+-${variant}}"
    src="${TMP}/${comp}/src"
    out_bins="${TMP}/${comp}/bins"
    DISP_DIR="${TMP}/${comp}/disp"
    stage="${TMP}/${comp}/stage"
    REPO_ROOT="${TMP}/${comp}/repo"
    EDGE_WEB="${TMP}/${comp}/edge.web"
    rm -rf "${TMP:?}/${comp}"
    mkdir -p "${src}" "${out_bins}" "${DISP_DIR}/${plat}" "${stage}" \
        "${REPO_ROOT}/inner/${comp}" "${EDGE_WEB}"
    local f
    # shellcheck disable=SC2086  # ${bins} is the same intentional space-list release.sh uses.
    for f in ${bins}; do printf 'bin:%s\n' "${f}" > "${out_bins}/${f}"; done
    DISP_NAME="$(channel_dispatcher "${CHANNEL}")"
    printf 'bin:%s\n' "${DISP_NAME}" > "${DISP_DIR}/${plat}/${DISP_NAME}"
}

# members — the finished zip's file entries, comma-joined, sorted. Read out of
# the ARCHIVE, never the staging dir: `zip -j` drops directory members after
# they were correctly staged, which is exactly how the gateway shipped broken.
members() { unzip -Z1 "$1" | grep -v '/$' | sort | paste -sd, -; }

run_public() { eval "${PUBLIC_ASSEMBLY}"; }
run_relay()  { eval "${RELAY_ASSEMBLY}"; }

# =============================================================================
# do_release — the four public components. This is the site that shipped
# gateway v0.2.0 without migrations/.
# =============================================================================

# --- cli: shared ladder + update.sh, install.sh from inner/<comp>/ -----------
fixture cli burrowee-cli
printf 'inner installer\n'     > "${REPO_ROOT}/inner/cli/install.sh"
printf 'component installer\n' > "${src}/install.sh"
printf 'update\n'              > "${src}/update.sh"
printf 'updater self-update\n' > "${src}/updater.update.sh"
shared_ladder_src "${src}"
if run_public; then ok "cli: assembly succeeds"; else bad "cli: assembly failed"; fi
# updater.update.sh exists in this fixture's source and must NOT ship: cli
# self-updates in-process, and the manifest is what decides that.
check "cli payload members" "$(members "${stage}/${asset}")" \
    "burrowee,burrowee-cli,install.sh,migrations/adopt_updater_unit.sh,migrations/adopt_user_tree.sh,migrations/component.conf,migrations/ledger,migrations/lib_paths.sh,migrations/lib_stale_user_bins.sh,migrations/repoint_lan_cert.sh,migrations/run.sh,migrations/stale_user_bins.sh,migrations/sweep_stale_exec_root.sh,migrations/upgrade.sh,update.sh"
check "cli install.sh comes from inner/cli/, not the component source" \
    "$(unzip -p "${stage}/${asset}" install.sh)" "inner installer"

# --- cli, darwin/amd64/legacy: the FIFTH platform threads through the same
# extracted release.sh text as every other target — asset name, dispatcher
# cache path and payload membership must be identical to the stock build,
# differing ONLY in the plat-derived names (never "darwin-amd64-''" or any
# other spelling of "no variant" leaking in from an empty-variant edge case).
os=darwin; arch=amd64; variant=legacy
fixture cli burrowee-cli
printf 'inner installer\n'     > "${REPO_ROOT}/inner/cli/install.sh"
printf 'component installer\n' > "${src}/install.sh"
printf 'update\n'              > "${src}/update.sh"
printf 'updater self-update\n' > "${src}/updater.update.sh"
shared_ladder_src "${src}"
if run_public; then ok "cli (darwin-amd64-legacy): assembly succeeds"; else bad "cli (darwin-amd64-legacy): assembly failed"; fi
check "cli (darwin-amd64-legacy) asset name" "${asset}" "burrowee-cli-darwin-amd64-legacy.zip"
[ -f "${stage}/burrowee-cli-darwin-amd64-legacy.zip" ] \
    && ok "cli (darwin-amd64-legacy) zip exists at the plat-derived path" \
    || bad "cli (darwin-amd64-legacy) zip missing at ${stage}/burrowee-cli-darwin-amd64-legacy.zip"
check "cli (darwin-amd64-legacy) payload members (same manifest as stock — VARIANT changes symbols, not membership)" \
    "$(members "${stage}/${asset}")" \
    "burrowee,burrowee-cli,install.sh,migrations/adopt_updater_unit.sh,migrations/adopt_user_tree.sh,migrations/component.conf,migrations/ledger,migrations/lib_paths.sh,migrations/lib_stale_user_bins.sh,migrations/repoint_lan_cert.sh,migrations/run.sh,migrations/stale_user_bins.sh,migrations/sweep_stale_exec_root.sh,migrations/upgrade.sh,update.sh"
os=darwin; arch=arm64; variant=""   # restore the default fixture platform for the rest of this file

# --- gateway: the regression, end to end through release.sh's own text -------
fixture gateway burrowee-gateway
printf 'inner installer\n' > "${REPO_ROOT}/inner/gateway/install.sh"
printf 'update\n'          > "${src}/update.sh"
mkdir -p "${src}/migrations"
printf '#!/bin/sh\nMIGRATIONS="\n0.2.0 v0_1_to_v0_2.sh\n"\n' > "${src}/migrations/run.sh"
printf '#!/bin/sh\n'                                     > "${src}/migrations/v0_1_to_v0_2.sh"
# the sweep library install.sh sources — assert_payload_migrations (inside the
# extracted block) requires it in the finished zip.
printf '#!/bin/sh\n'                                     > "${src}/migrations/lib_stale_user_bins.sh"
if run_public; then ok "gateway: assembly succeeds"; else bad "gateway: assembly failed"; fi
check "gateway payload members" "$(members "${stage}/${asset}")" \
    "burrowee,burrowee-gateway,guard.sh,install.sh,migrations/lib_stale_user_bins.sh,migrations/run.sh,migrations/v0_1_to_v0_2.sh,update.sh,updater.install.sh"

# --- gateway, beta channel: the twins, and only the twins --------------------
# The zip MEMBER names never change — a kit's entrypoint is install.sh on both
# channels, because the outer bootstrap that unpacks it is the same template.
# What changes is which FILE each member was copied from, and that is what this
# case reads back out of the archive rather than inferring from the staging dir.
CHANNEL=beta
fixture gateway burrowee-gateway
printf 'STABLE inner installer\n' > "${REPO_ROOT}/inner/gateway/install.sh"
printf 'BETA inner installer\n'   > "${REPO_ROOT}/inner/gateway/beta.install.sh"
printf 'update\n'          > "${src}/update.sh"
mkdir -p "${src}/migrations"
printf '#!/bin/sh\nMIGRATIONS="\n0.2.0 v0_1_to_v0_2.sh\n"\n' > "${src}/migrations/run.sh"
printf '#!/bin/sh\n'                                     > "${src}/migrations/v0_1_to_v0_2.sh"
printf '#!/bin/sh\n'                                     > "${src}/migrations/lib_stale_user_bins.sh"
if run_public; then ok "gateway (beta): assembly succeeds"; else bad "gateway (beta): assembly failed"; fi
check "gateway (beta) payload members — burroweeb, and the member names unchanged" \
    "$(members "${stage}/${asset}")" \
    "burrowee-gateway,burroweeb,guard.sh,install.sh,migrations/lib_stale_user_bins.sh,migrations/run.sh,migrations/v0_1_to_v0_2.sh,update.sh,updater.install.sh"
check "gateway (beta) install.sh is the BETA twin, not the stable original" \
    "$(unzip -p "${stage}/${asset}" install.sh)" "BETA inner installer"
CHANNEL=stable
fixture gateway burrowee-gateway
printf 'STABLE inner installer\n' > "${REPO_ROOT}/inner/gateway/install.sh"
printf 'BETA inner installer\n'   > "${REPO_ROOT}/inner/gateway/beta.install.sh"
printf 'update\n'          > "${src}/update.sh"
mkdir -p "${src}/migrations"
printf '#!/bin/sh\nMIGRATIONS="\n0.2.0 v0_1_to_v0_2.sh\n"\n' > "${src}/migrations/run.sh"
printf '#!/bin/sh\n'                                     > "${src}/migrations/v0_1_to_v0_2.sh"
printf '#!/bin/sh\n'                                     > "${src}/migrations/lib_stale_user_bins.sh"
if run_public; then ok "gateway (stable, twin present): assembly succeeds"; else bad "gateway (stable, twin present): assembly failed"; fi
check "a beta twin sitting in the tree does not reach a STABLE cut" \
    "$(unzip -p "${stage}/${asset}" install.sh)" "STABLE inner installer"

# --- edge: a directory member whose content comes from another tree ----------
fixture edge burrowee-edge
printf 'inner installer\n' > "${REPO_ROOT}/inner/edge/install.sh"
printf 'update\n'          > "${src}/update.sh"
printf 'updater self-update\n' > "${src}/updater.update.sh"
printf 'admin cover\n' > "${EDGE_WEB}/admin.html"
printf 'login cover\n' > "${EDGE_WEB}/login.html"
shared_ladder_src "${src}"
if run_public; then ok "edge: assembly succeeds"; else bad "edge: assembly failed"; fi
check "edge payload members" "$(members "${stage}/${asset}")" \
    "burrowee,burrowee-edge,covers/admin.html,covers/default.html,install.sh,migrations/adopt_updater_unit.sh,migrations/adopt_user_tree.sh,migrations/component.conf,migrations/ledger,migrations/lib_paths.sh,migrations/lib_stale_user_bins.sh,migrations/repoint_lan_cert.sh,migrations/run.sh,migrations/stale_user_bins.sh,migrations/sweep_stale_exec_root.sh,migrations/upgrade.sh,update.sh,updater.install.sh,updater.update.sh"
check "edge covers come from the edge.web tree, renamed" \
    "$(unzip -p "${stage}/${asset}" covers/default.html)" "login cover"

# =============================================================================
# do_release_relay — the PRIVATE, gated component, and the last site that
# open-coded its own list.
# =============================================================================

# --- (1) the invariant: what a relay payload carries --------------------------
# Stated literally, matching the published relay payload: 3 relay bins + the
# burrowee dispatcher + install.sh + update.sh + updater.update.sh + — since the
# 0.2.2 root-only collapse — the migrations/ ladder (the shared runner half plus
# relay's own component.conf, ledger and unit-derived adoption rung). Deriving
# this from payload_file_extras instead would make the assertion agree with the
# manifest by construction and certify nothing about the manifest.
fixture relay burrowee-relay burrowee-relay-cli burrowee-relay-updater
for f in install.sh update.sh updater.update.sh; do printf '%s\n' "${f}" > "${src}/${f}"; done
mkdir -p "${src}/migrations"
printf 'COMP=relay\n' > "${src}/migrations/component.conf"
printf '0.2.2 stale_user_bins.sh\n0.2.2 adopt_unit_home_tree.sh\n' > "${src}/migrations/ledger"
printf '#!/bin/sh\n' > "${src}/migrations/adopt_unit_home_tree.sh"
if run_relay; then ok "relay: assembly succeeds"; else bad "relay: assembly failed"; fi
check "relay payload members" "$(members "${stage}/${asset}")" \
    "burrowee,burrowee-relay,burrowee-relay-cli,burrowee-relay-updater,install.sh,migrations/adopt_unit_home_tree.sh,migrations/adopt_updater_unit.sh,migrations/adopt_user_tree.sh,migrations/component.conf,migrations/ledger,migrations/lib_paths.sh,migrations/lib_stale_user_bins.sh,migrations/repoint_lan_cert.sh,migrations/run.sh,migrations/stale_user_bins.sh,migrations/sweep_stale_exec_root.sh,migrations/upgrade.sh,update.sh,updater.update.sh"

# install.sh comes from the COMPONENT source on this path (the public components
# take theirs from inner/<comp>/install.sh, asserted above) — the one provenance
# difference that kept relay out of the shared manifest. Assert the bytes.
check "relay install.sh comes from the component source" \
    "$(unzip -p "${stage}/${asset}" install.sh)" "$(cat "${src}/install.sh")"

# --- (2) the manifest is what release.sh actually reads -----------------------
# Add a member to the manifest at run time and re-assemble. If release.sh reads
# the manifest, the new member ships; if it has gone back to an open-coded list,
# it does not — which is the regression this file exists to catch.
printf 'injected\n' > "${src}/relay.extra.sh"
payload_file_extras() {
    case "$1" in
        edge|relay)  printf '%s\n' update.sh updater.update.sh relay.extra.sh ;;
        gateway|cli) printf '%s\n' update.sh ;;
    esac
}
if run_relay; then ok "relay: assembly succeeds with an injected file member"; else bad "relay: assembly failed with an injected file member"; fi
check "release.sh ships a file member the manifest declares" \
    "$(members "${stage}/${asset}")" \
    "burrowee,burrowee-relay,burrowee-relay-cli,burrowee-relay-updater,install.sh,migrations/adopt_unit_home_tree.sh,migrations/adopt_updater_unit.sh,migrations/adopt_user_tree.sh,migrations/component.conf,migrations/ledger,migrations/lib_paths.sh,migrations/lib_stale_user_bins.sh,migrations/repoint_lan_cert.sh,migrations/run.sh,migrations/stale_user_bins.sh,migrations/sweep_stale_exec_root.sh,migrations/upgrade.sh,relay.extra.sh,update.sh,updater.update.sh"

# A declared member the source does not have must stop the cut here, not on the
# operator's node at self-update time.
rm "${src}/relay.extra.sh"
if ( run_relay ) >/dev/null 2>&1; then
    bad "relay: accepted a declared member missing from the source"
else ok "relay: refuses a declared member missing from the source"; fi
printf 'injected\n' > "${src}/relay.extra.sh"

# --- (3) a declared directory member that was never staged --------------------
# relay's migrations/ dir member and its survival through `zip -j` + the
# recursive pass are exercised for real by the member-list check in (1) — this
# half pins the OTHER edge: a declared directory member nothing staged is
# `zip error: Nothing to do!` without the guard, an abort naming neither the
# component nor the member.
# shellcheck disable=SC2329  # invoked indirectly, from the EVAL'd assembly block.
stage_payload_extras() { # file extras only — deliberately skip the migrations/ dir
    local s_="$2" d_="$3" n
    for n in update.sh updater.update.sh; do
        [ -f "${s_}/${n}" ] || return 1
        cp "${s_}/${n}" "${d_}/${n}"
    done
}
if ( run_relay ) >/dev/null 2>&1; then
    bad "relay: accepted a declared directory member that was never staged"
else ok "relay: refuses a declared directory member that was never staged"; fi

# --- a ledger row whose script is not staged refuses the whole cut ------------
# The 0.3.0 rung ships by glob (shared_migration_scripts), so nothing names it
# at assembly time except the component's ledger — which is exactly why a kit
# whose ledger names it while the shared directory lost it must refuse
# EVERYTHING here, at the cut, and never on a host: run.sh exits 1 on a ledger
# row with no file, which the outer bootstrap reads as a failed install.
os=darwin; arch=arm64; variant=""
fixture edge burrowee-edge
printf 'inner installer\n' > "${REPO_ROOT}/inner/edge/install.sh"
printf 'update\n'          > "${src}/update.sh"
printf 'updater self-update\n' > "${src}/updater.update.sh"
printf 'admin cover\n' > "${EDGE_WEB}/admin.html"
printf 'login cover\n' > "${EDGE_WEB}/login.html"
shared_ladder_src "${src}"
printf '0.2.0 stale_user_bins.sh\n0.3.0 sweep_stale_exec_root.sh\n' > "${src}/migrations/ledger"
rm "${SHARED_FIX}/sweep_stale_exec_root.sh"
if ( run_public ) >/dev/null 2>&1; then
    bad "edge: accepted a ledger naming the 0.3.0 rung with the script missing from the shared set"
else ok "edge: refuses a ledger naming the 0.3.0 rung with the script missing from the shared set"; fi
printf '#!/bin/sh\n' > "${SHARED_FIX}/sweep_stale_exec_root.sh"

if [ "${fail}" = 0 ]; then echo "ALL OK"; else echo "TESTS FAILED"; exit 1; fi

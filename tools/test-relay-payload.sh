#!/usr/bin/env bash
# test-relay-payload.sh — prove tools/release.sh's PRIVATE relay assembly ships
# exactly the shared manifest, by running release.sh's OWN TEXT.
#
# WHY THIS FILE EXISTS
# cmd/rkit/payload_manifest_test.go pins tools/payload.sh's manifest to
# cmd/rkit/assemble.go's. Neither of those is what a cut actually runs: every
# release to date was assembled by tools/release.sh, and the gateway v0.2.0
# defect lived precisely in the gap between the manifest and that orchestrator's
# own open-coded copy of it. do_release_relay held the last such copy —
# `for s in install.sh update.sh updater.update.sh` — kept because relay takes
# install.sh from its component source while the public components take theirs
# from inner/<comp>/install.sh.
#
# So this test does not re-state what relay carries and hope release.sh agrees.
# It EXTRACTS do_release_relay's assembly block from tools/release.sh, runs it
# over a fixture with stand-in binaries, and asserts the finished zip against:
#
#   1. a literal member list — the invariant, so mutating the manifest is caught
#      even though the assembly followed it faithfully; and
#   2. the manifest as computed at run time, with members INJECTED into it —
#      so re-open-coding a list in release.sh (the actual regression) shows up
#      as a member the manifest asked for and the zip does not have.
#
# No builds, no network, no keys: the binaries are files with known bytes,
# because what is under test is which members reach the archive, not what they
# contain.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HERE}/payload.sh"

fail=0
check() { # check <label> <got> <want>
    if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 — got '$2' want '$3'"; fail=1; fi
}
ok()  { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# --- the code under test ------------------------------------------------------
# do_release_relay's per-target assembly: from the line that names the staging
# dir through the last line before the zip is recorded. Pulled out of the
# shipped file so this cannot drift from what an operator runs.
ASSEMBLY="$(awk '/^do_release_relay\(\) \{/,/^\}/' "${HERE}/release.sh" \
    | awk '/^        assemble="\$\{stage\}/,/^        zips\+=\(/' \
    | grep -v '^        zips+=(')"

# Extraction is by pattern, so a rename in release.sh could silently yield an
# empty block that "passes" every assertion below. Refuse that outright.
if [ -z "${ASSEMBLY}" ] || ! printf '%s\n' "${ASSEMBLY}" | grep -q 'zip -j'; then
    echo "FAIL: could not extract do_release_relay's assembly block from release.sh" >&2
    echo "      (the markers moved — fix this test's extraction, do not delete it)" >&2
    exit 1
fi

# --- fixture ------------------------------------------------------------------
# relay_fixture <name> — a relay source tree + built-binary dir + dispatcher
# dir, and the variables the extracted block reads. Echoes the stage dir.
# shellcheck disable=SC2034  # every name here is read (or assigned) by the EVAL'd assembly block; shellcheck cannot see through eval.
{
    comp=relay
    os=darwin
    arch=arm64
    bins="burrowee-relay burrowee-relay-cli burrowee-relay-updater"
    APPLE_SIGN=""
    src="${TMP}/relay-src"
    out_bins="${TMP}/bins"
    DISP_DIR="${TMP}/disp"
    stage="${TMP}/stage"
    # The block assigns these; declared here so `set -u` is honest about what
    # the extracted code owns.
    assemble=""
    asset=""
    b=""
    d=""
}

mkdir -p "${src}" "${out_bins}" "${DISP_DIR}/${os}-${arch}" "${stage}"
for f in install.sh update.sh updater.update.sh; do printf '%s\n' "${f}" > "${src}/${f}"; done
# shellcheck disable=SC2086  # ${bins} is the same intentional space-list release.sh uses.
for f in ${bins}; do printf 'bin:%s\n' "${f}" > "${out_bins}/${f}"; done
printf 'bin:burrowee\n' > "${DISP_DIR}/${os}-${arch}/burrowee"

# members — the finished zip's entries, comma-joined, sorted. Read out of the
# ARCHIVE, never the staging dir: `zip -j` drops directory members after they
# are correctly staged, which is exactly how the gateway shipped broken.
members() { unzip -Z1 "$1" | sort | paste -sd, -; }

run_assembly() { eval "${ASSEMBLY}"; }

# --- (1) the invariant: what a relay payload carries --------------------------
# Stated literally, matching the published relay payload (7 members: 3 relay
# bins + the burrowee dispatcher + install.sh + update.sh + updater.update.sh).
# Deriving this from payload_file_extras instead would make the assertion agree
# with the manifest by construction and certify nothing about the manifest.
if run_assembly; then ok "assembly: succeeds"; else bad "assembly: failed"; fi
check "relay payload members" "$(members "${stage}/${asset}")" \
    "burrowee,burrowee-relay,burrowee-relay-cli,burrowee-relay-updater,install.sh,update.sh,updater.update.sh"

# install.sh comes from the COMPONENT source on this path (the public components
# take theirs from inner/<comp>/install.sh) — the one provenance difference that
# kept relay out of the shared manifest. Assert the bytes, not just the name.
unzip -p "${stage}/${asset}" install.sh > "${TMP}/got-install.sh"
check "relay install.sh comes from the component source" \
    "$(cat "${TMP}/got-install.sh")" "$(cat "${src}/install.sh")"

# --- (2) the manifest is what release.sh actually reads -----------------------
# Add a member to the manifest at run time and re-assemble. If release.sh reads
# the manifest, the new member ships; if it has gone back to an open-coded list,
# it does not — which is the regression this file exists to catch.
printf 'injected\n' > "${src}/relay.extra.sh"
payload_file_extras() {
    case "$1" in
        edge|relay) printf '%s\n' update.sh updater.update.sh relay.extra.sh ;;
        gateway|cli) printf '%s\n' update.sh ;;
    esac
}
if run_assembly; then ok "assembly: succeeds with an injected file member"; else bad "assembly: failed with an injected file member"; fi
check "release.sh ships a file member the manifest declares" \
    "$(members "${stage}/${asset}")" \
    "burrowee,burrowee-relay,burrowee-relay-cli,burrowee-relay-updater,install.sh,relay.extra.sh,update.sh,updater.update.sh"

# A declared member the source does not have must stop the cut here, not on the
# operator's node at self-update time.
rm "${src}/relay.extra.sh"
if ( run_assembly ) >/dev/null 2>&1; then
    bad "assembly: accepted a declared member missing from the source"
else ok "assembly: refuses a declared member missing from the source"; fi
printf 'injected\n' > "${src}/relay.extra.sh"

# --- (3) directory members survive the archive --------------------------------
# `zip -j` skips directories outright, so a directory member needs the second
# recursive pass. relay declares none today, which is exactly why this is worth
# asserting: the pass is unexercised code until a member appears, and an
# unexercised pass is what gateway/migrations/ was missing.
payload_dir_extras() {
    case "$1" in
        edge)          printf '%s\n' covers ;;
        gateway|relay) printf '%s\n' migrations ;;
    esac
}
mkdir -p "${TMP}/mig"
printf '#!/bin/sh\n' > "${TMP}/mig/run.sh"
# shellcheck disable=SC2329  # invoked indirectly, from the EVAL'd assembly block.
stage_payload_extras() { # keep the file extras, and stage the directory member
    local c="$1" s_="$2" d_="$3" n
    for n in $(payload_file_extras "${c}"); do
        [ -f "${s_}/${n}" ] || return 1
        cp "${s_}/${n}" "${d_}/${n}"
    done
    mkdir -p "${d_}/migrations" && cp "${TMP}/mig/run.sh" "${d_}/migrations/run.sh"
}
if run_assembly; then ok "assembly: succeeds with a directory member"; else bad "assembly: failed with a directory member"; fi
check "release.sh keeps a directory member's path in the zip" \
    "$(unzip -Z1 "${stage}/${asset}" | grep '^migrations/' | grep -v '/$' | sort | paste -sd, -)" \
    "migrations/run.sh"

# A declared directory member that was never staged is `zip error: Nothing to
# do!` without this guard — an abort naming neither component nor member.
stage_payload_extras() {
    local c="$1" s_="$2" d_="$3" n
    for n in $(payload_file_extras "${c}"); do
        [ -f "${s_}/${n}" ] || return 1
        cp "${s_}/${n}" "${d_}/${n}"
    done
}
if ( run_assembly ) >/dev/null 2>&1; then
    bad "assembly: accepted a declared directory member that was never staged"
else ok "assembly: refuses a declared directory member that was never staged"; fi

if [ "${fail}" = 0 ]; then echo "ALL OK"; else echo "TESTS FAILED"; exit 1; fi

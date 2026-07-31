#!/usr/bin/env bash
# test-version-floor.sh — prove the outer bootstrap will not accept a
# network-RESOLVED version older than the floor baked into it.
#
# Why the floor exists: the trusted-comment binding (test-tag-binding.sh) checks
# the signed release against $TAG. When api.github.com is unreachable, $TAG is
# itself answered by a GH_PROXY mirror or the console catalog — the same party
# that then serves the artifacts — so the binding compares that party's answer
# against itself, and ANY older, genuinely signed release passes. @MIN_VERSION@
# is the one input in that comparison a download source cannot choose: it is
# baked from versions/<comp>.stamp by gen-bootstraps.sh and reaches the host over
# the first-party static channel, in the same fetch that delivered @PUBKEY@.
#
# What this covers:
#   PREDICATE:  semver_of / is_semver / version_ge / assert_version_floor,
#               extracted VERBATIM from the generated cli/install.sh (between the
#               "BEGIN version-floor" / "END version-floor" markers) and driven
#               directly — the shipped code, not a copy of it.
#   BAKE:       every generated <comp>/install.sh carries a floor byte-equal to
#               versions/<comp>.stamp (a stale or unsubstituted floor is a
#               released-installer bug, not a test-only one).
#   FAIL-CLOSED: an unbaked/placeholder floor aborts rather than waving the
#               resolved version through.
#   GENERATOR:  gen-bootstraps.sh refuses to bake a floor with no comparable
#               X.Y.Z prefix instead of emitting one the runtime must reject.
#
# Fully hermetic: no network, no minisign, no servers, nothing installed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\n✗ VERSION-FLOOR TEST FAILED: %s\n' "$*" >&2; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/test-version-floor-XXXXXX")"
trap 'rm -rf "${W}"' EXIT INT TERM

COMPS="cli gateway edge agent"

# ---- (1) BAKE: the generated bootstraps carry the recorded stamps ------------
say "BAKE: every <comp>/install.sh bakes versions/<comp>.stamp as its floor"
for comp in ${COMPS}; do
    [ -f "${REPO_ROOT}/versions/${comp}.stamp" ] \
        || die "versions/${comp}.stamp is missing — the floor has no source"
    want="$(tr -d '[:space:]' < "${REPO_ROOT}/versions/${comp}.stamp")"
    got="$(sed -n 's/^MIN_VERSION="\(.*\)"$/\1/p' "${REPO_ROOT}/${comp}/install.sh")"
    [ -n "${got}" ] \
        || die "${comp}/install.sh has no MIN_VERSION line — regenerate with tools/gen-bootstraps.sh"
    [ "${got}" = "${want}" ] \
        || die "${comp}/install.sh bakes floor '${got}' but versions/${comp}.stamp says '${want}' — re-run tools/gen-bootstraps.sh"
done
printf '  OK: all four floors match their stamp files\n'

# ---- (2) extract the shipped predicate --------------------------------------
# The block is delimited in tools/bootstrap.template.sh; pull it out of the
# GENERATED cli/install.sh so the test drives the exact bytes that ship.
say "PREDICATE: extracting the version-floor block from cli/install.sh"
sed -n '/^# BEGIN version-floor/,/^# END version-floor/p' \
    "${REPO_ROOT}/cli/install.sh" > "${W}/floor.sh"
grep -q '^# END version-floor' "${W}/floor.sh" \
    || die "could not extract the version-floor block from cli/install.sh (markers missing or renamed)"
for fn in semver_of is_semver version_ge assert_version_floor; do
    grep -q "^${fn}()" "${W}/floor.sh" || die "extracted block does not define ${fn}()"
done

# ---- (3) PREDICATE: comparison table ----------------------------------------
# Driven in a child shell so `fail` can exit without killing this script.
# shellcheck disable=SC2016  # the heredoc body is deliberately unexpanded here.
cat > "${W}/run.sh" <<'RUNNER'
#!/bin/sh
set -eu
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
info() { :; }
ok()   { :; }
. "$1"          # the extracted floor block
MIN_VERSION="$2"
assert_version_floor "$3"
RUNNER
chmod +x "${W}/run.sh"

# floor_check <floor> <tag> -> exit status of the shipped assert_version_floor
floor_check() {
    sh "${W}/run.sh" "${W}/floor.sh" "$1" "$2" >/dev/null 2>&1
}

say "PREDICATE: accepted / rejected version pairs"
# accept: <floor> <tag>   — same version, newer patch, newer minor, newer major
for pair in \
    "v0.1.74.2026.07.31.53d7e671|cli/v0.1.74.2026.07.31.53d7e671" \
    "v0.1.74.2026.07.31.53d7e671|cli/v0.1.75.2026.08.01.aaaaaaaa" \
    "v0.1.74.2026.07.31.53d7e671|cli/v0.2.0.2026.08.01.aaaaaaaa" \
    "v0.1.74.2026.07.31.53d7e671|cli/v1.0.0.2026.08.01.aaaaaaaa" \
    "v0.1.9.2026.07.01.aaaaaaaa|cli/v0.1.10.2026.07.02.bbbbbbbb" \
    "v0.1.74.2026.07.31.53d7e671|cli/v0.1.74.2025.01.01.00000000" ; do
    floor="${pair%%|*}"; tag="${pair#*|}"
    floor_check "${floor}" "${tag}" \
        || die "floor ${floor} wrongly REJECTED ${tag}"
done
printf '  OK: newer / equal versions accepted\n'

# reject: the rollback shapes, plus anything uncomparable (fail closed)
for pair in \
    "v0.1.74.2026.07.31.53d7e671|cli/v0.1.10.2026.01.01.0ldc0de0" \
    "v0.1.74.2026.07.31.53d7e671|cli/v0.1.73.2026.07.30.aaaaaaaa" \
    "v0.1.74.2026.07.31.53d7e671|cli/v0.0.9.2026.01.01.aaaaaaaa" \
    "v0.2.0.2026.07.31.53d7e671|cli/v0.1.99.2026.07.30.aaaaaaaa" \
    "v1.0.0.2026.07.31.53d7e671|cli/v0.9.9.2026.07.30.aaaaaaaa" \
    "v0.1.74.2026.07.31.53d7e671|cli/vlatest" \
    "v0.1.74.2026.07.31.53d7e671|cli/v0.1" \
    "v0.1.74.2026.07.31.53d7e671|cli/" ; do
    floor="${pair%%|*}"; tag="${pair#*|}"
    ! floor_check "${floor}" "${tag}" \
        || die "floor ${floor} wrongly ACCEPTED ${tag} — this is the silent-rollback vector"
done
printf '  OK: older and uncomparable versions rejected\n'

# ---- (4) FAIL-CLOSED: an unbaked floor must abort, not wave things through ---
say "FAIL-CLOSED: an unbaked/placeholder floor rejects even a plausible version"
for bad_floor in "" "@MIN_VERSION@" "PLACEHOLDER" "vTEMP"; do
    ! floor_check "${bad_floor}" "cli/v9.9.9.2026.08.01.aaaaaaaa" \
        || die "floor '${bad_floor}' accepted a resolved version — an installer without a real floor must refuse network resolution"
done
printf '  OK: no floor means no network-resolved install\n'

# ---- (5) GENERATOR: an uncomparable stamp is refused at bake time -----------
say "GENERATOR: gen-bootstraps.sh refuses a floor with no numeric X.Y.Z prefix"
if BURROWEE_MIN_VERSION="not-a-version" sh tools/gen-bootstraps.sh >/dev/null 2>&1; then
    # Restore whatever that render wrote before failing.
    sh tools/gen-bootstraps.sh >/dev/null 2>&1 || true
    die "gen-bootstraps.sh baked an uncomparable floor instead of failing"
fi
printf '  OK: generator fails closed on an uncomparable stamp\n'

# The failing render above aborts on the first component, but may already have
# rewritten a preflight; re-render from the real stamps so the worktree is clean.
sh tools/gen-bootstraps.sh >/dev/null

printf '\n  VERSION-FLOOR TEST PASSED (bake + predicate + fail-closed + generator)\n'

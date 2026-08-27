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
#   RESOLVER:   the shipped resolution flow — also extracted verbatim — walks
#               EVERY page of /releases (a component whose head has scrolled off
#               page 1 must not resolve to its own older release), applies the
#               floor to GitHub/mirror answers, and does NOT apply it to the
#               first-party console catalog (which serves the last PROMOTED
#               release and so legitimately trails the cut the floor is baked
#               from — flooring it would abort every install in that window).
#
# Fully hermetic: no network, no minisign, no servers, nothing installed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\n✗ VERSION-FLOOR TEST FAILED: %s\n' "$*" >&2; exit 1; }
check() { # check <label> <got> <want>
    [ "$2" = "$3" ] || die "$1 — got '$2' want '$3'"
}

# ---- work dir + cleanup ------------------------------------------------------
# Section (5) re-renders the bootstraps (deliberately with a bad floor), so this
# script MUTATES tracked files. Save their pre-test bytes and restore THOSE on
# exit — never `git checkout`, which would also throw away a contributor's
# uncommitted work (same pattern as tools/test-tag-binding.sh).
W="$(mktemp -d "${TMPDIR:-/tmp}/test-version-floor-XXXXXX")"

COMPS="cli gateway edge agent"
GENERATED="cli/install.sh gateway/install.sh edge/install.sh agent/install.sh relay/install.sh
cli/upgrade.sh gateway/upgrade.sh edge/upgrade.sh agent/upgrade.sh
cli/preflight.sh gateway/preflight.sh edge/preflight.sh agent/preflight.sh
edge/updater.install.sh gateway/updater.install.sh"

mkdir -p "${W}/orig"
for f in ${GENERATED}; do
    mkdir -p "${W}/orig/$(dirname "${f}")"
    cp "${REPO_ROOT}/${f}" "${W}/orig/${f}"
done

cleanup() {
    for g in ${GENERATED}; do
        if [ -f "${W}/orig/${g}" ]; then cp "${W}/orig/${g}" "${REPO_ROOT}/${g}"; fi
    done
    rm -rf "${W}"
}
trap cleanup EXIT INT TERM

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
# This render (and the aborted partial it leaves behind) is why this script has
# a save-and-restore trap — the cleanup above puts every generated file back.
if BURROWEE_MIN_VERSION="not-a-version" sh tools/gen-bootstraps.sh >/dev/null 2>&1; then
    die "gen-bootstraps.sh baked an uncomparable floor instead of failing"
fi
printf '  OK: generator fails closed on an uncomparable stamp\n'

# Restore now, not just on exit: the resolver section below extracts blocks from
# cli/install.sh and must read the checked-in bytes, not a half-written render.
cleanup_restore() {
    for g in ${GENERATED}; do
        if [ -f "${W}/orig/${g}" ]; then cp "${W}/orig/${g}" "${REPO_ROOT}/${g}"; fi
    done
}
cleanup_restore

# ---- (6) RESOLVER: pagination, and who the floor is applied to --------------
# The floor block is only half the story: WHICH tag it is handed comes out of the
# resolution flow. Extract that flow (and the resolver helpers it calls) verbatim
# from the generated cli/install.sh, exactly as section (2) does for the floor,
# and drive it against a stub $CURL. Still hermetic: no network, no servers.
say "RESOLVER: extracting the resolver + version-resolve blocks from cli/install.sh"
sed -n '/^# BEGIN release-resolver/,/^# END release-resolver/p' \
    "${REPO_ROOT}/cli/install.sh" > "${W}/resolver.sh"
sed -n '/^# BEGIN version-resolve/,/^# END version-resolve/p' \
    "${REPO_ROOT}/cli/install.sh" > "${W}/resolve.sh"
grep -q '^# END release-resolver' "${W}/resolver.sh" \
    || die "could not extract the release-resolver block from cli/install.sh (markers missing or renamed)"
grep -q '^# END version-resolve' "${W}/resolve.sh" \
    || die "could not extract the version-resolve block from cli/install.sh (markers missing or renamed)"
for fn in latest_tag next_page_url resolve_latest; do
    grep -q "^${fn}()" "${W}/resolver.sh" || die "extracted resolver block does not define ${fn}()"
done

# Driver: sources the three extracted blocks and prints the resolved tag. $CURL
# is a stub serving canned bodies/headers out of ${STUB_FIXTURES}; a URL with no
# fixture behaves like an unreachable host.
cat > "${W}/resolve-run.sh" <<'RUNNER'
#!/bin/sh
set -eu
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
info() { :; }
ok()   { :; }

COMP=cli
CHANNEL=stable
REPO=burrowee-git/release
DL_BASE=""
BURROWEE_CLI_VERSION=""        # no operator pin: exercise the resolution flow
GH_PROXIES="${STUB_PROXIES:-}"
CONSOLE_URL="https://console.invalid"
MIN_VERSION="${STUB_FLOOR}"
CURL=stub_curl

stub_curl() {
    _out=""; _hdr=""; _url=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -o) _out="$2"; shift 2 ;;
            -D) _hdr="$2"; shift 2 ;;
            -*) shift ;;
            *)  _url="$1"; shift ;;
        esac
    done
    _slug="$(printf '%s' "${_url}" | sed 's/[^A-Za-z0-9]/_/g')"
    [ -f "${STUB_FIXTURES}/${_slug}.body" ] || return 7   # curl: could not connect
    if [ -n "${_hdr}" ]; then
        if [ -f "${STUB_FIXTURES}/${_slug}.head" ]; then
            cat "${STUB_FIXTURES}/${_slug}.head" > "${_hdr}"
        else
            : > "${_hdr}"
        fi
    fi
    if [ -n "${_out}" ]; then
        cat "${STUB_FIXTURES}/${_slug}.body" > "${_out}"
    else
        cat "${STUB_FIXTURES}/${_slug}.body"
    fi
}

. "${STUB_BLOCKS}/resolver.sh"
. "${STUB_BLOCKS}/floor.sh"
. "${STUB_BLOCKS}/resolve.sh"
printf '%s\n' "${TAG}"
RUNNER
chmod +x "${W}/resolve-run.sh"

API_URL="https://api.github.com/repos/burrowee-git/release/releases?per_page=100"
CATALOG_URL="https://console.invalid/api/v1/releases/cli/current?channel=stable"

slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/_/g'; }

# fixture <dir> <url> <body> [<headers>]
fixture() {
    local dir="$1" url="$2" body="$3" head="${4:-}"
    mkdir -p "${dir}"
    printf '%s' "${body}" > "${dir}/$(slug "${url}").body"
    [ -z "${head}" ] || printf '%s' "${head}" > "${dir}/$(slug "${url}").head"
}

# resolve <fixture-dir> <floor> <proxies> -> prints resolved tag, exits non-zero
# exactly where the shipped installer would abort.
resolve() {
    local tmp="${W}/run-tmp"
    rm -rf "${tmp}"; mkdir -p "${tmp}"
    STUB_BLOCKS="${W}" STUB_FIXTURES="$1" STUB_FLOOR="$2" STUB_PROXIES="$3" TMP="${tmp}" \
        sh "${W}/resolve-run.sh" 2>&1
}

FLOOR="v0.1.75.2026.07.31.a38dd8fc"

# (6a) PAGINATION — cli's newest release lives on page 2. A single-page resolver
# answers cli/v0.1.10 (that component's own OLDER release, not "nothing"), which
# the floor then turns into an install that cannot succeed without a manual pin.
say "RESOLVER: the newest release is found even when it is not on page 1"
PG="${W}/fx-pages"
fixture "${PG}" "${API_URL}" \
    '[{"tag_name":"gateway/v0.1.108.2026.07.31.d5698b26"},{"tag_name":"cli/v0.1.10.2026.01.01.00000000"}]' \
    "HTTP/2 200
link: <${API_URL}&page=2>; rel=\"next\", <${API_URL}&page=2>; rel=\"last\"
"
fixture "${PG}" "${API_URL}&page=2" \
    '[{"tag_name":"cli/v0.1.99.2026.07.31.deadbeef"},{"tag_name":"agent/v0.1.8.2026.07.26.e0142d45"}]'
got="$(resolve "${PG}" "${FLOOR}" "")" \
    || die "paginated resolution failed:\n${got}"
[ "${got##*$'\n'}" = "cli/v0.1.99.2026.07.31.deadbeef" ] \
    || die "resolver answered '${got}' — expected the page-2 head cli/v0.1.99.2026.07.31.deadbeef (an unpaginated resolver stops at page 1 and answers an OLDER release of the same component)"
printf '  OK: Link rel="next" is followed; the head release wins\n'

# (6b) A "next" link off api.github.com is ignored — a mirror writes these headers.
say "RESOLVER: an off-host Link: rel=\"next\" is not followed"
OFF="${W}/fx-offhost"
fixture "${OFF}" "${API_URL}" \
    '[{"tag_name":"cli/v0.1.99.2026.07.31.deadbeef"}]' \
    "HTTP/2 200
link: <https://evil.invalid/releases?page=2>; rel=\"next\"
"
fixture "${OFF}" "https://evil.invalid/releases?page=2" \
    '[{"tag_name":"cli/v9.9.9.2026.08.01.aaaaaaaa"}]'
got="$(resolve "${OFF}" "${FLOOR}" "")" || die "off-host link run failed:\n${got}"
[ "${got##*$'\n'}" = "cli/v0.1.99.2026.07.31.deadbeef" ] \
    || die "resolver followed an off-host next link (answered '${got}')"
printf '  OK: pagination stays on api.github.com\n'

# (6c) FLOOR APPLIES to a mirror — GitHub's API is dark, a mirror answers with an
# older (genuinely signed) release. This is the silent-rollback vector.
say "RESOLVER: a mirror answering below the floor still aborts"
MIR="${W}/fx-mirror"
mkdir -p "${MIR}"
fixture "${MIR}" "https://mirror.invalid/${API_URL}" \
    '[{"tag_name":"cli/v0.1.10.2026.01.01.00000000"}]'
fixture "${MIR}" "${CATALOG_URL}" '{"version":"cli/v0.1.70.2026.07.20.bbbbbbbb"}'
if got="$(resolve "${MIR}" "${FLOOR}" "https://mirror.invalid")"; then
    die "a mirror resolved below the floor and was ACCEPTED ('${got}') — this is the silent-rollback vector"
fi
case "${got}" in
    *"version floor not met"*) : ;;
    *) die "mirror rollback aborted, but not on the version floor; got:\n${got}" ;;
esac
printf '  OK: mirror answers are still held to the floor\n'

# (6d) FLOOR DOES NOT APPLY to the console catalog. The catalog serves the last
# PROMOTED release; the floor is baked from the just-CUT stamp. In the cut→promote
# window the catalog legitimately answers older, and it is the ONLY resolver a
# GitHub-blocked host has — flooring it aborts that host's install with "retry
# when github.com is reachable", the one thing it cannot do.
say "RESOLVER: the console catalog may answer below the floor (cut→promote window)"
CAT="${W}/fx-catalog"
fixture "${CAT}" "${CATALOG_URL}" '{"version":"cli/v0.1.70.2026.07.20.bbbbbbbb","component":"cli"}'
got="$(resolve "${CAT}" "${FLOOR}" "")" \
    || die "catalog resolution below the floor was REJECTED — a host on a GitHub-blocked network has no other path; got:\n${got}"
[ "${got##*$'\n'}" = "cli/v0.1.70.2026.07.20.bbbbbbbb" ] \
    || die "catalog resolved '${got}', expected cli/v0.1.70.2026.07.20.bbbbbbbb"
case "${got}" in
    *"Retry when github.com is reachable"*)
        die "the catalog path still prints the unactionable 'retry when github.com is reachable' advice" ;;
esac
printf '  OK: catalog answers install; the floor is not applied there\n'

# (6e) The catalog is still shape-checked — a foreign or malformed version aborts.
say "RESOLVER: the catalog cannot name another component or a junk version"
BAD="${W}/fx-catalog-bad"
fixture "${BAD}" "${CATALOG_URL}" '{"version":"gateway/v0.1.108.2026.07.31.d5698b26"}'
if got="$(resolve "${BAD}" "${FLOOR}" "")"; then
    die "the catalog named another component's release and it was accepted ('${got}')"
fi
printf '  OK: catalog answers are shape-checked before use\n'

# ---- (7) CHANNEL: latest_tag() matches only its own channel's tag shape -----
# A stable resolve must ignore a higher beta, and a beta resolve must ignore
# every stable, in both orderings — the property that keeps a beta tag from
# ever reaching a stable install.sh and vice versa. Drive latest_tag() directly
# (already extracted into resolver.sh above) against canned page bodies on
# stdin, with and without jq on PATH — the same two code paths latest_tag()
# itself branches on.
say "CHANNEL: latest_tag() filters by \$CHANNEL, with and without jq"
cat > "${W}/latest-tag-run.sh" <<'RUNNER'
#!/bin/sh
set -eu
. "$1"
latest_tag
RUNNER
chmod +x "${W}/latest-tag-run.sh"

# run_latest_tag <comp> <channel> <path> — reads the page JSON on stdin.
run_latest_tag() {
    COMP="$1" CHANNEL="$2" PATH="$3" sh "${W}/latest-tag-run.sh" "${W}/resolver.sh"
}

# A curated bin dir, not a trimmed system PATH: some hosts (this one included)
# ship a real /usr/bin/jq, so "/usr/bin:/bin" would still find it and silently
# skip the no-jq branch. Symlink only what latest_tag()'s grep/sed fallback
# needs, deliberately omitting jq, then PROVE it is really gone before trusting it.
NO_JQ_DIR="${W}/no-jq-bin"
mkdir -p "${NO_JQ_DIR}"
for _njt in sh grep sed sort tail; do
    # type -p, not command -v: a shell FUNCTION named grep/sed/etc. (this host
    # has one) makes `command -v` print the bare name back, which then
    # symlinks to itself and disappears. type -p only ever names a real file.
    _njp="$(type -p "${_njt}" 2>/dev/null || true)"
    [ -n "${_njp}" ] || die "cannot build a no-jq PATH: '${_njt}' not found on this host"
    ln -sf "${_njp}" "${NO_JQ_DIR}/${_njt}"
done
NO_JQ_PATH="${NO_JQ_DIR}"
if PATH="${NO_JQ_PATH}" command -v jq >/dev/null 2>&1; then
    die "NO_JQ_PATH (${NO_JQ_PATH}) still finds jq on this host — fix the curated no-jq bin dir so the no-jq branch is really exercised"
fi

# mk_page <tag_name>... — a GitHub-shaped /releases page body: pretty-printed,
# one field per line (the real api.github.com response shape — confirmed by
# inspection above), NOT the minified single-line JSON the grep/sed fallback's
# line-anchored match cannot see a "tag_name" field inside. The jq branch reads
# either shape; this is what makes the grep/sed branch exercisable at all.
mk_page() {
    printf '[\n'
    _mkp_first=1
    for _mkp_t in "$@"; do
        [ "${_mkp_first}" = 1 ] || printf ',\n'
        _mkp_first=0
        printf '  {\n    "tag_name": "%s"\n  }' "${_mkp_t}"
    done
    printf '\n]\n'
}

run_channel_pairs() {
    _rcp_path="$1"
    _rcp_label="$2"
    page="$(mk_page cli/v0.3.0.beta.2026.08.28.1f0c9e2a cli/v0.2.9.2026.08.28.aa21f55c cli/v0.2.8.2026.08.27.7a56bdc5)"
    check "stable ignores a higher beta (${_rcp_label})" \
        "$(printf '%s' "${page}" | run_latest_tag cli stable "${_rcp_path}")" \
        "cli/v0.2.9.2026.08.28.aa21f55c"
    check "beta ignores every stable (${_rcp_label})" \
        "$(printf '%s' "${page}" | run_latest_tag cli beta "${_rcp_path}")" \
        "cli/v0.3.0.beta.2026.08.28.1f0c9e2a"
    page2="$(mk_page cli/v0.3.1.2026.08.29.aa21f55c cli/v0.3.0.beta.2026.08.28.1f0c9e2a)"
    check "beta ignores a higher stable (${_rcp_label})" \
        "$(printf '%s' "${page2}" | run_latest_tag cli beta "${_rcp_path}")" \
        "cli/v0.3.0.beta.2026.08.28.1f0c9e2a"
    page3="$(mk_page cli/v0.2.9.2026.08.28.aa21f55c)"
    check "beta with no beta tags is empty (${_rcp_label})" \
        "$(printf '%s' "${page3}" | run_latest_tag cli beta "${_rcp_path}")" \
        ""
}

if command -v jq >/dev/null 2>&1; then
    run_channel_pairs "${PATH}" "with jq"
else
    printf '  (skipping the with-jq pass — no jq on this host'"'"'s PATH)\n'
fi
run_channel_pairs "${NO_JQ_PATH}" "without jq"
printf '  OK: latest_tag() never crosses channels, with or without jq\n'

printf '\n  VERSION-FLOOR TEST PASSED (bake + predicate + fail-closed + generator + resolver + channel)\n'

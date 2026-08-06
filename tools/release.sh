#!/usr/bin/env bash
# release.sh — cut a signed Burrowee component release (cli | gateway | edge | agent).
#
# Usage:
#   bash tools/release.sh <cli|gateway|edge|agent|relay|all> [--apple] [--vulncheck|--public] [--dry-run] [--bump-minor|--bump-major] [--force]
#
# --force: bump + mint a fresh stamp even when the component's source is
#   unchanged since its last cut (versions/<comp>.stamp's recorded sha8 +
#   semver both match). Without it, an unchanged component under the default
#   patch bump is REUSED verbatim (no bump, no date churn) — see
#   resolve_comp_stamp() below. Rare use case: re-shipping a component whose
#   bundled dispatcher changed but whose own source didn't.
#
# --apple: Developer ID sign the darwin binaries (modernech-sign, Modernech LLC)
#   + notarize each darwin zip before publishing. WITHOUT it darwin bins are
#   ad-hoc signed (the default) — fine for curl-install (no quarantine xattr).
#   NOTE: --apple ALONE signs+notarizes but SKIPS the CVE gate; for a public,
#   browser-downloadable release use --public (signing + govulncheck).
#   --apple on its own is the conscious sign-only exception. Guideline:
#   ~/.claude/guidelines/APPLE-SIGNING.md.
#
# --vulncheck: hard-gate the cut on govulncheck — scans every shipped module
#   and aborts on any finding. --public is shorthand for --apple --vulncheck
#   (the standard ship path). Neither flag + an interactive TTY prompts to cut
#   a public release (both); a non-interactive run or a "no" answer skips both.
#   (--public-release is kept as a back-compat alias for --public.)
#
# For each requested component this:
#   1. Stamps the version via tools/version.sh — bumps (patch/minor/major)
#      ONLY when the component's source actually changed since its last cut,
#      or --force/--bump-minor/--bump-major was given; otherwise reuses the
#      last cut's recorded stamp verbatim (no bump, no date churn). See
#      resolve_comp_stamp() below. Never bumps on --dry-run.
#   2. Builds the `burrowee` dispatcher once per target (its own stamp).
#   3. Cross-compiles the component for darwin/{arm64,amd64} + linux/{arm64,amd64},
#      assembling each target into dist/<stamp>/burrowee-<comp>-<os>-<arch>/ that
#      carries the component bins + `burrowee` + the inner installer renamed to
#      install.sh, then `zip -j`s it.
#   4. Writes a sorted SHA256SUMS.txt over the four zips.
#   5. Signs SHA256SUMS.txt with minisign (real key from release.dp, or the TEST
#      key on --dry-run).
#   6. (non-dry-run) git-tags <comp>/<stamp> + publishes a GitHub Release.
#   7. (non-dry-run) regenerates the bootstraps, refreshes the edge skills, and
#      scp's the static surface to the release host.
#   8. (non-dry-run) records a [RELEASED: <comp>] marker commit.
#
# The relay target is a PRIVATE publish (uploads to R2).
# It does NOT push a GitHub Release or git tag. It does:
#   - Build 4 platform zips + SHA256SUMS.txt + .minisig (same as public comps).
#   - Upload zips + SHA256SUMS.txt + .minisig to R2 under relay/<stamp>/.
#   - Update top-level latest.* set (latest.<os>-<arch>.zip + SHA256SUMS.txt + .minisig).
#
# On --dry-run only steps 1-5 run, and the version bump is REVERTED — the tree is
# left exactly as it was, just with throwaway artifacts under dist/<stamp>/.
#
# Env (all optional — sane defaults below):
#   RELEASE_HOST            ssh alias for the nginx static host (default nsm.renative.com)
#   STATIC_DIR              absolute static dir on that host
#   DP_DIR                  path to the release.dp secrets repo
#   SIGN_KEY                minisign secret key file (overrides the default resolution)
#   AGE_IDENTITY            age identity file used to decrypt the real signing key
#                           (default ~/.age/burrowee-release.txt — created at activation A2)
#   BURROWEE_SRC_CLI        cli component source tree — DRY-RUN ONLY; a real cut
#   BURROWEE_SRC_GATEWAY    is refused unless the source is the registry main
#   BURROWEE_SRC_EDGE       folder (<Brand>/<comp>/code/<comp>), primary
#   BURROWEE_SRC_AGENT      worktree, on main, clean, == origin/main.
#   BURROWEE_SRC_DISPATCHER See tools/cut_origin.sh.
#   BURROWEE_SRC_RELAY
#   EDGE_WEB_DIR            edge.web tree (admin.html/login.html covers baked into
#                           the edge payload) — DRY-RUN ONLY; a real cut is refused
#                           unless the source is the registry main folder
#                           (<Brand>/edge.web/code/edge.web), primary worktree, on
#                           main, clean, == origin/main. See tools/cut_origin.sh.
#   BURROWEE_RELEASE_REPO   GitHub repo for releases (default burrowee-git/release)
#   BURROWEE_RELEASE_YES    skip the interactive minor/major bump confirm
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=tools/vulncheck.sh
source "${REPO_ROOT}/tools/vulncheck.sh"
# shellcheck source=tools/apple_sign.sh
source "${REPO_ROOT}/tools/apple_sign.sh"
# shellcheck source=tools/updater_pin.sh
source "${REPO_ROOT}/tools/updater_pin.sh"
# shellcheck source=tools/cut_origin.sh
source "${REPO_ROOT}/tools/cut_origin.sh"

# ---- go on PATH (the Burrowee per-dir hook strips /opt/homebrew/bin) ---------
GO_BIN="${GO_BIN:-go}"
command -v "${GO_BIN}" >/dev/null 2>&1 || GO_BIN=/opt/homebrew/bin/go
export GO_BIN

# ---- Component source trees. REG_* are the registry main folders — the ONLY
# paths a real cut may build from (tools/cut_origin.sh, is_registry_source).
# SRC_* keep the documented BURROWEE_SRC_*/EDGE_WEB_DIR overrides, which
# assert_cut_origin then accepts only under --dry-run: keeping the variables
# and refusing them is better than deleting them, because silently ignoring a
# variable an operator set is how a cut ends up building something nobody
# asked for.
#
# Defined ahead of build_register_helper/the publish intercept (below) — not in
# their original position further down the file — so the publish entry point
# can call assert_cut_origins (and the src_for it depends on) before it does
# any work. Nothing here depends on the arg-parsing section that used to
# precede it: every value below reads only REPO_ROOT, BB, and the operator's
# environment.
BB="/Volumes/MacintoshED/Workstation/Coding/Burrowee"
REG_CLI="${BB}/cli/code/cli"
REG_GATEWAY="${BB}/gateway/code/gateway"
REG_EDGE="${BB}/edge/code/edge"
REG_EDGE_WEB="${BB}/edge.web/code/edge.web"
REG_AGENT="${BB}/agent/code/agent"
REG_DISPATCHER="${BB}/burrowee/code/burrowee"
REG_RELAY="${BB}/relay/code/relay"
REG_RELEASE="${BB}/release/code/release"

SRC_CLI="${BURROWEE_SRC_CLI:-${REG_CLI}}"
SRC_GATEWAY="${BURROWEE_SRC_GATEWAY:-${REG_GATEWAY}}"
SRC_EDGE="${BURROWEE_SRC_EDGE:-${REG_EDGE}}"
SRC_AGENT="${BURROWEE_SRC_AGENT:-${REG_AGENT}}"
SRC_DISPATCHER="${BURROWEE_SRC_DISPATCHER:-${REG_DISPATCHER}}"
SRC_RELAY="${BURROWEE_SRC_RELAY:-${REG_RELAY}}"
EDGE_WEB="${EDGE_WEB_DIR:-${REG_EDGE_WEB}}"

# registry_src_for <comp> — the registry path for a component, mirroring
# src_for()'s table so the two cannot disagree about which components exist.
registry_src_for() {
    case "$1" in
        cli)     printf '%s' "${REG_CLI}" ;;
        gateway) printf '%s' "${REG_GATEWAY}" ;;
        edge)    printf '%s' "${REG_EDGE}" ;;
        agent)   printf '%s' "${REG_AGENT}" ;;
        relay)   printf '%s' "${REG_RELAY}" ;;
        *) echo "registry_src_for: unknown component: $1" >&2; return 1 ;;
    esac
}

src_for() {
    case "$1" in
        cli)     printf '%s' "${SRC_CLI}" ;;
        gateway) printf '%s' "${SRC_GATEWAY}" ;;
        edge)    printf '%s' "${SRC_EDGE}" ;;
        agent)   printf '%s' "${SRC_AGENT}" ;;
        relay)   printf '%s' "${SRC_RELAY}" ;;
    esac
}

# Paths the RELEASE REPO may carry staged when the guard runs. Empty for every
# entry point except --distribute-only, which is preceded by an `rkit build` that
# stages the component's version + stamp so both ride the [RELEASED] marker commit.
# Forwarded to the release-repo assertion ONLY: no component tree ever gets it.
RELEASE_REPO_STAGED_OK=()

# assert_cut_origins <mode> <comp...> — the guard over every tree a cut or a
# distribute reads or writes. Called from ALL THREE entry points: `publish`
# (below — no component trees, just the release repo itself), a
# --distribute-only publish (mutates exactly as much as a full cut: tag,
# GitHub Release, versions/<comp>, the [RELEASED: …] marker, the static host),
# and the full cut.
#
# edge.web (REG_EDGE_WEB/EDGE_WEB) is asserted whenever "edge" appears in the
# component list — the same "is edge in scope" shape the full-cut path already
# uses to decide whether to pull in the edge skills tree (needs_edge, further
# down): a real edge cut reads admin.html/login.html out of that tree and
# bakes them into the payload, so it gets the same guard as every other tree a
# cut builds from.
assert_cut_origins() {
    local mode="$1"; shift
    local comp src
    for comp in "$@"; do
        src="$(src_for "${comp}")"
        [ -d "${src}" ] || { echo "✗ ${comp} source worktree missing: ${src}" >&2; return 1; }
        assert_cut_origin "${comp}" "${src}" "$(registry_src_for "${comp}")" "${mode}" || return 1
    done
    case " $* " in
        *" edge "*)
            [ -d "${EDGE_WEB}" ] || { echo "✗ edge.web source worktree missing: ${EDGE_WEB}" >&2; return 1; }
            assert_cut_origin edge.web "${EDGE_WEB}" "${REG_EDGE_WEB}" "${mode}" || return 1
            ;;
    esac
    [ -d "${SRC_DISPATCHER}" ] || { echo "✗ dispatcher source worktree missing: ${SRC_DISPATCHER}" >&2; return 1; }
    assert_cut_origin dispatcher "${SRC_DISPATCHER}" "${REG_DISPATCHER}" "${mode}" || return 1
    assert_cut_origin "release repo" "${REPO_ROOT}" "${REG_RELEASE}" "${mode}" \
        ${RELEASE_REPO_STAGED_OK[@]+"${RELEASE_REPO_STAGED_OK[@]}"} || return 1
}

# ---- build_register_helper: compile burrowee-release-register to dist/.tools/ ----
# Called from both the publish intercept and the release-cut flow.
REGISTER_BIN="${REPO_ROOT}/dist/.tools/burrowee-release-register"
build_register_helper() {
    mkdir -p "${REPO_ROOT}/dist/.tools"
    echo "→ building burrowee-release-register helper" >&2
    "${GO_BIN}" build -buildvcs=false -o "${REGISTER_BIN}" ./cmd/burrowee-release-register \
        || { echo "✗ failed to build burrowee-release-register" >&2; exit 1; }
}

# ---- publish: push a promoted version's public binaries to R2 ----------------
# Handled before the normal arg loop so the release-cut pre-flight (signing key,
# ssh, ghp) is never entered.
#
# publish has no --dry-run — every invocation mutates (a production R2 upload
# via internal/register/publish.go, then a retention report), so it is held to
# STRICT mode: asserted BEFORE build_register_helper compiles anything or the
# register helper touches R2, not after. No component tree is asserted (this
# path never reads cli/gateway/edge/agent/relay source) — only the dispatcher
# and the release repo itself, via assert_cut_origins' unconditional tail.
#
# After the R2 push, retention is reported (NOT applied): the R2 prune-to-10 and
# the GitHub prune-to-10 both run DRY-RUN so the cut surfaces what is now over
# the retention limit. The destructive drain (--execute) is a deploy-phase step,
# never run automatically from a publish.
if [ "${1:-}" = "publish" ]; then
    shift
    comp="${1:-}"
    [ -n "${comp}" ] || { echo "usage: release.sh publish <cli|gateway|edge|agent|all> [--version <v>]" >&2; exit 1; }
    shift || true
    assert_cut_origins strict || exit 1
    build_register_helper
    "${REGISTER_BIN}" publish --comp "${comp}" "$@"
    echo
    echo "→ retention (dry-run — run prune with --execute in the deploy phase to apply):"
    "${REGISTER_BIN}" prune --comp "${comp}" || true
    # GitHub prune scope is cli/gateway/edge only (relay has no GitHub release).
    gh_comps="${comp}"
    [ "${comp}" = all ] && gh_comps="cli gateway edge agent"
    COMPONENTS="${gh_comps}" bash "${REPO_ROOT}/tools/prune-releases.sh" || true
    exit 0
fi

# ---- args -------------------------------------------------------------------
WHAT=""
DRY_RUN=0
BUMP_KIND="patch"
FORCE_BUMP=0

# Apple account resolution + the Developer-ID reachability predicates live in
# tools/apple_sign.sh (sourced above) so tools/apple_sign.test.sh can exercise
# them without any part of the release path running.

APPLE_SIGN=""
VULNCHECK=""
DISTRIBUTE_ONLY=0
DIST_COMP=""
DIST_STAMP=""
# --distribute-only <comp> <stamp> [--dry-run]: takes its component + stamp as
# positional args right after the flag (not from the general WHAT/comp case
# below), so it's consumed here before the normal arg loop runs.
if [ "${1:-}" = "--distribute-only" ]; then
    DISTRIBUTE_ONLY=1
    shift
    DIST_COMP="${1:-}"
    DIST_STAMP="${2:-}"
    [ -n "${DIST_COMP}" ] && [ -n "${DIST_STAMP}" ] \
        || { echo "✗ usage: release.sh --distribute-only <cli|gateway|edge|agent> <stamp> [--dry-run]" >&2; exit 2; }
    shift 2
fi
for arg in "$@"; do
    case "${arg}" in
        cli|gateway|edge|agent|relay|all) WHAT="${arg}" ;;
        --apple)              APPLE_SIGN=1 ;;
        --vulncheck)          VULNCHECK=1 ;;
        --public)             APPLE_SIGN=1; VULNCHECK=1 ;;
        --public-release)     APPLE_SIGN=1; VULNCHECK=1 ;;  # back-compat alias for --public
        --dry-run)            DRY_RUN=1 ;;
        --bump-minor)         BUMP_KIND="minor" ;;
        --bump-major)         BUMP_KIND="major" ;;
        --force)              FORCE_BUMP=1 ;;
        -h|--help)            sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "✗ unknown argument: ${arg}" >&2; exit 2 ;;
    esac
done
if [ "${DISTRIBUTE_ONLY}" = 1 ]; then
    [ -z "${WHAT}" ] || { echo "✗ --distribute-only takes <comp> <stamp> as its own args — drop the trailing '${WHAT}'" >&2; exit 2; }
else
    [ -n "${WHAT}" ] || { echo "✗ usage: release.sh <cli|gateway|edge|agent|relay|all> [--apple] [--vulncheck|--public] [--dry-run] [--bump-minor|--bump-major] [--force]" >&2; exit 2; }
fi

# When neither signing nor the CVE gate was requested and we're interactive,
# offer the --public path (both). Non-TTY or no answer → dev/testing.
# --distribute-only never signs or CVE-gates (that already happened upstream in
# `rkit build`), so it skips this prompt entirely.
if [ "${DISTRIBUTE_ONLY}" != 1 ]; then
    PROMPT_ANS=""
    if [ -z "${APPLE_SIGN}" ] && [ -z "${VULNCHECK}" ] && [ -t 0 ]; then
        printf 'Cut a PUBLIC release? — Developer-ID signing + CVE gate  [y/N] ' >&2
        read -r PROMPT_ANS || PROMPT_ANS=""
    fi
    _mode="$(resolve_release_mode "${APPLE_SIGN}" "${VULNCHECK}" "${PROMPT_ANS}")"
    APPLE_SIGN="${_mode%%|*}"; VULNCHECK="${_mode#*|}"
    export APPLE_SIGN VULNCHECK
    # Indented into the block it belongs to, and an explicit `exit 1` rather than
    # an AND-OR list: a column-0 `[ … ] && load_apple_account` read as if it sat
    # outside this `if`, and left the resolution's failure as the block's exit
    # status instead of stopping the cut.
    if [ -n "${APPLE_SIGN}" ]; then
        load_apple_account "${REPO_ROOT}" || exit 1
    fi
fi

# ---- config / defaults ------------------------------------------------------
RELEASE_HOST="${RELEASE_HOST:-nsm.renative.com}"
STATIC_DIR="${STATIC_DIR:-/ebs_storage/apps/release.burrowee.com/static}"
RELEASE_REPO="${BURROWEE_RELEASE_REPO:-burrowee-git/release}"
DP_DIR="${DP_DIR:-${REPO_ROOT}/../../../release.dp/code/release.dp}"
AGE_KEY_AGE="${DP_DIR}/burrowee-release.key.age"
AGE_IDENTITY="${AGE_IDENTITY:-${HOME}/.age/burrowee-release.txt}"

# REG_*/SRC_*/EDGE_WEB/registry_src_for/src_for/assert_cut_origins are defined
# earlier in this file (right after GO_BIN is resolved) — moved there so the
# `publish` intercept above can assert the release repo before it does any
# work. See the comments at their definition.

# resolve_disp_stamp — the dispatcher stamp to bundle/register this cut. Reuses
# the recorded versions/burrowee.stamp verbatim (date frozen) when the
# dispatcher source is unchanged; else mints a fresh stamp (today) and records
# it so it rides the [RELEASED] marker. Keeps dispatcher_version stable until
# the dispatcher source actually changes, instead of churning on every cut's
# date. Defined here (ahead of the --distribute-only early-exit below) so
# every DISP_STAMP call site — distribute_relay, distribute_only, and the
# dispatcher build-cache section — resolves the same way.
DISP_STAMP_FILE="${REPO_ROOT}/versions/burrowee.stamp"
resolve_disp_stamp() {
    local cur_sha semver recorded rec_sha rec_sv fresh
    cur_sha="$(git -C "${SRC_DISPATCHER}" rev-parse --short=8 HEAD)"
    semver="$(SRC_DIR="${SRC_DISPATCHER}" bash "${REPO_ROOT}/tools/version.sh" burrowee --semver | tr -d '[:space:]')"
    if [ -f "${DISP_STAMP_FILE}" ]; then
        recorded="$(tr -d '[:space:]' < "${DISP_STAMP_FILE}")"
        rec_sha="${recorded##*.}"                 # trailing sha8 segment
        rec_sv="$(printf '%s' "${recorded}" | sed -E 's/^v([0-9]+\.[0-9]+\.[0-9]+)\..*/\1/')"
        if [ "${rec_sha}" = "${cur_sha}" ] && [ "${rec_sv}" = "${semver}" ]; then
            printf '%s' "${recorded}"; return 0   # unchanged → reuse (date frozen)
        fi
    fi
    fresh="$(SRC_DIR="${SRC_DISPATCHER}" bash "${REPO_ROOT}/tools/version.sh" burrowee --stamp | tr -d '[:space:]')"
    if [ "${DRY_RUN:-0}" != 1 ]; then
        printf '%s\n' "${fresh}" > "${DISP_STAMP_FILE}"
        # Rides the [RELEASED] marker commit; if the cut aborts before that
        # commit, revert_dispatcher_version() (below, in the EXIT/INT/TERM
        # trap) restores this staged write so a never-released date isn't
        # left behind for the next unchanged-source cut to reuse.
        ( cd "${REPO_ROOT}" && git add "versions/burrowee.stamp" )
    fi
    printf '%s' "${fresh}"
}

# resolve_comp_stamp <comp> <src_dir> — generalizes resolve_disp_stamp (above)
# from the dispatcher-only freeze to EVERY component. Reuses the recorded
# versions/<comp>.stamp verbatim (semver + date + changeset all frozen) when
# the default bump is in effect (BUMP_KIND=patch, not --force'd) AND the
# component source is unchanged since the last cut (recorded sha8 + semver
# segment both still match); else bumps versions/<comp> per BUMP_KIND, mints a
# fresh stamp, and records it so it rides the [RELEASED] marker. Unlike the
# dispatcher (which is NEVER auto-bumped), a routine per-component cut still
# bumps on a real source change — only the needless churn on an UNCHANGED
# component is eliminated.
#
# --dry-run never bumps (matches pre-freeze behavior): echoes the recorded
# stamp when unchanged, else a fresh stamp over the CURRENT (unbumped)
# semver — regardless of BUMP_KIND/--force, since dry-run mints nothing.
#
# Callers: stamp="$(resolve_comp_stamp "${comp}" "${src}")" in do_release()
# and do_release_relay(). On a real bump, the caller's revert_version /
# revert_relay_version traps must ALSO revert versions/<comp>.stamp (mirrors
# revert_dispatcher_version reverting versions/burrowee.stamp) — see those
# functions below.
resolve_comp_stamp() {
    local comp="$1" src_dir="$2"
    local cur_sha semver stamp_file recorded rec_sha rec_sv unchanged=0 fresh

    cur_sha="$(git -C "${src_dir}" rev-parse --short=8 HEAD)"
    semver="$(SRC_DIR="${src_dir}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --semver | tr -d '[:space:]')"
    stamp_file="${REPO_ROOT}/versions/${comp}.stamp"

    if [ -f "${stamp_file}" ]; then
        recorded="$(tr -d '[:space:]' < "${stamp_file}")"
        rec_sha="${recorded##*.}"                 # trailing sha8 segment
        rec_sv="$(printf '%s' "${recorded}" | sed -E 's/^v([0-9]+\.[0-9]+\.[0-9]+)\..*/\1/')"
        if [ "${rec_sha}" = "${cur_sha}" ] && [ "${rec_sv}" = "${semver}" ]; then
            unchanged=1
        fi
    fi

    if [ "${DRY_RUN:-0}" = 1 ]; then
        if [ "${unchanged}" = 1 ]; then
            printf '%s' "${recorded}"
        else
            SRC_DIR="${src_dir}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --stamp | tr -d '[:space:]'
        fi
        return 0
    fi

    if [ "${unchanged}" = 1 ] && [ "${BUMP_KIND}" = patch ] && [ "${FORCE_BUMP:-0}" != 1 ]; then
        printf '%s' "${recorded}"; return 0   # unchanged, default bump → reuse (no bump)
    fi

    case "${BUMP_KIND}" in
        patch) SRC_DIR="${src_dir}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --bump-patch >/dev/null ;;
        minor) SRC_DIR="${src_dir}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --bump-minor >/dev/null ;;
        major) SRC_DIR="${src_dir}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --bump-major >/dev/null ;;
    esac
    fresh="$(SRC_DIR="${src_dir}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --stamp | tr -d '[:space:]')"
    printf '%s\n' "${fresh}" > "${stamp_file}"
    # Rides the [RELEASED] marker commit; if the cut aborts before that
    # commit, the caller's revert_version/revert_relay_version trap restores
    # this staged write so a never-released date isn't left behind for the
    # next unchanged-source cut to wrongly reuse.
    ( cd "${REPO_ROOT}" && git add "versions/${comp}.stamp" )
    printf '%s' "${fresh}"
}

# edge skills source-of-truth (the edge repo owns these)
EDGE_SKILLS_SRC="${SRC_EDGE}/skills"

TARGETS=(
    "darwin arm64"
    "darwin amd64"
    "linux arm64"
    "linux amd64"
)

# src_for is defined earlier in this file, beside REG_*/SRC_*/assert_cut_origins.

# binary list per component (the dispatcher `burrowee` is added at assembly time)
bins_for() {
    case "$1" in
        cli)     printf '%s' "burrowee-cli burrowee-cli-updater" ;;
        gateway) printf '%s' "burrowee-gateway burrowee-gateway-cli burrowee-gateway-console burrowee-register burrowee-gateway-updater" ;;
        edge)    printf '%s' "burrowee-edge burrowee-edge-cli burrowee-edge-updater" ;;
        agent)   printf '%s' "burrowee-agent" ;;
        relay)   printf '%s' "burrowee-relay burrowee-relay-cli burrowee-relay-updater" ;;
    esac
}

GHP="$(command -v ghp 2>/dev/null || echo "${HOME}/bin/ghp")"

# ---- console registration (Phase C) -----------------------------------------
# register_staged <comp> <stamp> <semver> <stage_dir> <src_dir> [<gh_tag>]
#
# Builds an artifacts JSON from the four per-platform zips in <stage_dir>,
# then calls burrowee-release-register to record a `staged` release row in
# the console via the pubkey/nonce handshake.
#
# Config-optional: if ~/.burrowee/release/config.toml is absent, prints a
# warning and returns 0 (never fails the release).
# Dry-run-safe: when DRY_RUN=1, prints the would-register body and returns 0
# without touching config or keys.
# Post-failure non-fatal: if the helper fails, warns loudly but does not exit.
#
# For public comps: url_or_key is the GitHub asset download URL.
# For relay: url_or_key is the R2 key under relay/<stamp>/.
# gated=true iff comp==relay. github_release=<comp>/<stamp> for public, ""
# for relay. prerelease=true always.
warn() { echo "⚠ $*" >&2; }
register_staged() {
    local comp="$1" stamp="$2" semver="$3" stage_dir="$4" src_dir="$5"
    local gh_tag="${6:-}"

    local gated=false
    local github_release="${gh_tag}"
    [ "${comp}" = relay ] && gated=true && github_release=""

    # json_escape: emit the INTERIOR of a JSON string (no surrounding quotes) so
    # the existing "key":"$(json_escape …)" call sites stay unchanged. `jq -Rs`
    # reads the whole raw arg as one string and escapes everything JSON requires —
    # \, ", control chars (\n \t \r \b \f, U+0000–U+001F) — which the old sed
    # (only \ and ") did not. The trailing slice strips jq's surrounding quotes
    # (jq -Rs . always emits `"<escaped>"` on a single line).
    json_escape() {
        local q
        q="$(printf '%s' "$1" | jq -Rs .)"
        # drop the leading and trailing double-quote jq adds.
        q="${q#\"}"
        q="${q%\"}"
        printf '%s' "$q"
    }

    # source_sha: git HEAD of the component source repo.
    local source_sha
    source_sha="$(/usr/bin/git -C "${src_dir}" rev-parse HEAD 2>/dev/null || echo '')"

    # sha256_bundle: sha256 of SHA256SUMS.txt (covers all four platform zips).
    local sha256_bundle
    # shellcheck disable=SC2086
    sha256_bundle="$(${SHA256} "${stage_dir}/SHA256SUMS.txt" 2>/dev/null | awk '{print $1}')" || sha256_bundle=""

    # Build artifacts JSON.
    # For each platform zip, extract sha256 + size, derive url_or_key.
    # Public comps: zips are named burrowee-<comp>-<os>-<arch>.zip in stage_dir.
    # Relay: zips are named latest.<os>-<arch>.zip in stage_dir (the latest_stage).
    local artifacts_json="{" first=1
    for pair in "darwin arm64" "darwin amd64" "linux arm64" "linux amd64"; do
        local os arch
        # shellcheck disable=SC2086  # pair is a controlled two-word string; word-splitting gives os arch.
        read -r os arch <<<"${pair}"
        local plat="${os}-${arch}"

        local zip_name url_or_key zip_path
        if [ "${comp}" = relay ]; then
            zip_name="latest.${plat}.zip"
            url_or_key="relay/${stamp}/${zip_name}"
        else
            zip_name="burrowee-${comp}-${plat}.zip"
            url_or_key="https://github.com/${RELEASE_REPO}/releases/download/${gh_tag}/${zip_name}"
        fi
        zip_path="${stage_dir}/${zip_name}"

        if [ ! -f "${zip_path}" ]; then
            echo "⚠ console registration: zip not found: ${zip_path} — skipping" >&2
            return 0
        fi

        # sha256: read from SHA256SUMS.txt (already computed) for consistency.
        local sha256
        # SHA256SUMS.txt lines: "<hash>  <filename>" (shasum) or "<hash>  <filename>" (sha256sum)
        sha256="$(grep " ${zip_name}$" "${stage_dir}/SHA256SUMS.txt" 2>/dev/null | awk '{print $1}')"
        if [ -z "${sha256}" ]; then
            # Fallback: compute directly.
            # shellcheck disable=SC2086
            sha256="$(${SHA256} "${zip_path}" | awk '{print $1}')"
        fi

        # size in bytes.
        local size
        size="$(wc -c < "${zip_path}" | tr -d ' ')"

        local sep=""
        [ "${first}" = 1 ] || sep=","
        first=0
        artifacts_json="${artifacts_json}${sep}\"${plat}\":{\"url_or_key\":\"$(json_escape "${url_or_key}")\",\"sha256\":\"$(json_escape "${sha256}")\",\"size\":${size}}"
    done
    artifacts_json="${artifacts_json}}"

    # sums_ref and minisig_ref: public = GitHub asset URLs; relay = R2 keys.
    local sums_ref minisig_ref
    if [ "${comp}" = relay ]; then
        sums_ref="relay/${stamp}/SHA256SUMS.txt"
        minisig_ref="relay/${stamp}/SHA256SUMS.txt.minisig"
    else
        sums_ref="https://github.com/${RELEASE_REPO}/releases/download/${gh_tag}/SHA256SUMS.txt"
        minisig_ref="https://github.com/${RELEASE_REPO}/releases/download/${gh_tag}/SHA256SUMS.txt.minisig"
    fi

    # binaries: the product's first-party sub-module names as a JSON array.
    # dispatcher_version: the burrowee stamp bundled into this product's zip.
    local binaries_json
    local -a bins
    read -r -a bins <<< "$(bins_for "${comp}")"
    binaries_json="$(printf '%s\n' "${bins[@]}" | jq -Rsc 'split("\n") | map(select(length>0))')"

    # updater_version: the FULL updater stamp (<semver>.<YYYY.MM.DD>.<sha8>)
    # bundled into this release's -updater binary (mirrors dispatcher_version's
    # nullability — DISP_STAMP is resolved by version.sh under this script's
    # `set -euo pipefail` and hard-fails a cut rather than ever becoming "";
    # updater_version must carry the same guarantee, not silently swallow a
    # resolution error). Resolved from the component's updater module dir: the
    # root module for cli/gateway/edge, the NESTED `cli` module for relay
    # (cli/go.mod pins core/updater separately from the relay root module —
    # same distinction updater_pin() itself makes). agent ships no -updater
    # binary and has no core/updater dependency at all — it is the ONLY
    # component whose updater_version is legitimately "".
    #
    # updater_pin <mod-dir> (tools/updater_pin.sh, sourced above) is the SAME
    # helper build.sh uses and the SAME contract rkit's relconfig.UpdaterPin
    # mirrors — this used to be a local resolve_updater_pin() that only
    # resolved the bare `go list -m` tag (not the full stamp) and never called
    # the shared helper, so the console catalog carried a different string
    # than the binary's -X main.version for the same pin. Calling the shared
    # helper directly closes that gap: it hard-fails (stderr message +
    # non-zero) on an unresolvable module, a pseudo-version, or a malformed
    # Time/Origin.Hash, so a cut (including distribute_relay(), which
    # re-resolves this pin fresh at distribution time) can never silently ship
    # an empty, bare, or malformed updater_version.
    local updater_mod_dir="${src_dir}"
    [ "${comp}" = relay ] && updater_mod_dir="${src_dir}/cli"
    local updater_ver=""
    [ "${comp}" = agent ] || updater_ver="$(updater_pin "${updater_mod_dir}")"

    local body
    # artifacts is sent as a JSON *string* (console stores it as an opaque JSON blob); object-shaped would 400.
    body="{\"component\":\"$(json_escape "${comp}")\",\"version\":\"$(json_escape "${stamp}")\",\"semver\":\"$(json_escape "${semver}")\",\"gated\":${gated},\"artifacts\":\"$(json_escape "${artifacts_json}")\",\"sums_ref\":\"$(json_escape "${sums_ref}")\",\"minisig_ref\":\"$(json_escape "${minisig_ref}")\",\"github_release\":\"$(json_escape "${github_release}")\",\"prerelease\":true,\"source_sha\":\"$(json_escape "${source_sha}")\",\"sha256\":\"$(json_escape "${sha256_bundle}")\",\"notes\":\"\",\"binaries\":${binaries_json},\"dispatcher_version\":\"$(json_escape "${DISP_STAMP}")\",\"updater_version\":\"$(json_escape "${updater_ver}")\"}"

    if [ "${DRY_RUN}" = 1 ]; then
        echo "→ dry-run: would register ${comp} ${stamp} via burrowee-release-register"
        echo "  body: ${body}"
        return 0
    fi

    # Config-optional: skip if the release identity directory is not provisioned.
    if [ ! -f "${HOME}/.burrowee/release/config.toml" ]; then
        warn "console registration skipped: ~/.burrowee/release not configured"
        return 0
    fi

    printf '%s' "${body}" > "${stage_dir}/.register-payload.json"
    if ! "${REGISTER_BIN}" register --payload-file "${stage_dir}/.register-payload.json"; then
        warn "console registration failed for ${comp} ${stamp}; register manually later"
    fi
    return 0
}

# ---- gh_release_publish: tag + GitHub Release for a staged component --------
# gh_release_publish <comp> <stamp> <stage_dir>
#
# Shared by the full-cut path (do_release, below) and --distribute-only (one
# publish implementation, DRY). Resolves the component source worktree itself
# (src_for) for the change-summary git log, so both callers get identical
# behavior regardless of which entry point invoked it.
gh_release_publish() {
    local comp="$1" stamp="$2" stage="$3"
    local src; src="$(src_for "${comp}")"

    command -v ghp >/dev/null 2>&1 || { echo "✗ required tool not found: ghp" >&2; exit 1; }
    [ -x "${GHP}" ] || { echo "✗ ghp wrapper not found at ${GHP}" >&2; exit 1; }
    "${GHP}" repo view "${RELEASE_REPO}" --json name >/dev/null 2>&1 \
        || { echo "✗ ghp cannot access ${RELEASE_REPO} — check gh.account + auth" >&2; exit 1; }

    # Change summary: component commits since the previous release's source sha.
    # The stamp's trailing field IS the 8-char source sha, so the previous
    # release's sha is the suffix of the highest existing <comp>/v… tag.
    local prev_tag prev_sha changes
    prev_tag="$(/usr/bin/git tag -l "${comp}/v*" --sort=version:refname | tail -n1)"
    prev_sha="${prev_tag##*.}"
    if [ -n "${prev_sha}" ] && git -C "${src}" cat-file -e "${prev_sha}^{commit}" 2>/dev/null; then
        changes="$(git -C "${src}" log --oneline --no-merges "${prev_sha}..HEAD" 2>/dev/null)"
        [ -n "${changes}" ] || changes="No code changes since ${prev_tag} (re-release)."
    else
        changes="Initial release."
    fi

    local tag="${comp}/${stamp}"
    if git rev-parse "refs/tags/${tag}" >/dev/null 2>&1; then
        echo "✗ tag ${tag} already exists locally — reverting version" >&2; exit 1
    fi
    git tag -a "${tag}" -m "burrowee ${comp} ${stamp}"

    local notes; notes="${stage}/release-notes.md"
    cat > "${notes}" <<NOTES
burrowee ${comp} ${stamp} — $(date -u +%Y-%m-%d)

## Changes
${changes}

Install:
  curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/${comp}/install.sh | sh

Pin this version:
  BURROWEE_$(printf '%s' "${comp}" | tr '[:lower:]' '[:upper:]')_VERSION=${tag} \\
    curl -fsSL https://release.burrowee.com/${comp}/install.sh | sh

Verify by hand:
  minisign -Vm SHA256SUMS.txt -P "\$(cat burrowee-release.pub | tail -n1)"
  shasum -a 256 -c SHA256SUMS.txt
NOTES

    ( cd "${stage}" && "${GHP}" -R "${RELEASE_REPO}" release create "${tag}" \
        --title "${comp} ${stamp}" --notes-file "${notes}" \
        burrowee-"${comp}"-*.zip SHA256SUMS.txt SHA256SUMS.txt.minisig )
}

# ---- distribute_only: distribution-only mode over an already-staged dist/<stamp>/
# (produced by `rkit build` — the produce half lives there now). Runs ONLY:
# GitHub Release (gh_release_publish) -> gen-bootstraps.sh -> self-hosting
# upload (scp install.sh/preflight.sh/pubkey/site/skills to the release host,
# mirrored from do_release()) -> [RELEASED] marker commit -> register_staged
# (console catalog, LAST — only after everything above is actually live) ->
# GitHub retention report. No build, no sign, no notarize, no CVE gate, no
# version bump — all of that already happened upstream.
# relay is out of scope (private R2-only publish, no GitHub Release — see
# do_release_relay).
# On --dry-run: validates the staged dir + component, then STUBS every publish
# action (prints "would: ..." lines) and returns — no register_staged call, no
# ghp/git/gen-bootstraps/ssh/scp invocation, no writes of any kind.
#
# relay is handled by distribute_relay() below: a PRIVATE R2-only publish (no
# GitHub Release, no self-hosting scp), reusing do_release_relay's R2 steps over
# rkit's already-built dist/<stamp>/ artifacts.

# ---- distribute_relay: private R2 distribution over rkit's staged artifacts ---
# rkit build --component relay produces dist/<stamp>/burrowee-relay-<os>-<arch>.zip
# (+ SHA256SUMS/minisig over THOSE names). The R2 flow serves stable
# latest.<os>-<arch>.zip filenames the installer hard-codes, so re-stage the zips
# under those names and re-sign SHA256SUMS over the renamed set (identical bytes,
# different filenames), then publish to R2. No GitHub Release, no scp.
# On --dry-run: re-stage + re-sign with the TEST key and print the would-upload
# R2 keys — no publish-relay, no register, no commit.
distribute_relay() {
    local stamp="$1" comp=relay
    local stage="${REPO_ROOT}/dist/${stamp}"
    [ -d "${stage}" ] || { echo "✗ staged dir missing: ${stage} (run rkit build --component relay first)" >&2; exit 1; }
    local src semver
    src="$(src_for "${comp}")"
    [ -d "${src}" ] || { echo "✗ relay source worktree missing: ${src}" >&2; exit 1; }
    semver="$(SRC_DIR="${src}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --semver)"

    if command -v shasum >/dev/null 2>&1; then SHA256="shasum -a 256"
    elif command -v sha256sum >/dev/null 2>&1; then SHA256="sha256sum"
    else echo "✗ neither shasum nor sha256sum found" >&2; exit 1; fi

    # (1) re-stage rkit's burrowee-relay-<os>-<arch>.zip under latest.* names.
    local latest_stage="${stage}/.latest"
    rm -rf "${latest_stage}"; mkdir -p "${latest_stage}"
    local pair os arch z
    for pair in "${TARGETS[@]}"; do
        read -r os arch <<<"${pair}"
        z="${stage}/burrowee-${comp}-${os}-${arch}.zip"
        [ -f "${z}" ] || { echo "✗ missing ${z} (run rkit build --component relay first)" >&2; exit 1; }
        cp "${z}" "${latest_stage}/latest.${os}-${arch}.zip"
    done
    # shellcheck disable=SC2086
    ( cd "${latest_stage}" && ${SHA256} latest.*.zip | sort > SHA256SUMS.txt )

    # (2) resolve the signing key (inline — resolve_sign_key is defined past the
    # DISTRIBUTE_ONLY dispatch) and re-sign SHA256SUMS over the latest.* names.
    # The REAL key is decrypted into the SHARED ${SHRED_FILE}, never a local, so
    # the shred_key trap registered above the DISTRIBUTE_ONLY dispatch covers
    # this entry point: a minisign failure or a Ctrl-C between the decrypt and
    # the cleanup must not leave the plaintext key on disk, and it must be
    # overwritten rather than plain-rm'd (rm alone leaves it recoverable).
    local sign_key
    if [ -n "${SIGN_KEY:-}" ]; then
        sign_key="${SIGN_KEY}"
        [ -f "${sign_key}" ] || { echo "✗ SIGN_KEY not found: ${sign_key}" >&2; exit 1; }
    elif [ "${DRY_RUN}" = 1 ]; then
        sign_key="${REPO_ROOT}/tools/testkeys/test.key"
        [ -f "${sign_key}" ] || { echo "✗ TEST key missing: ${sign_key}" >&2; exit 1; }
    else
        [ -f "${AGE_IDENTITY}" ] || { echo "✗ age identity not found: ${AGE_IDENTITY}" >&2; exit 1; }
        [ -f "${AGE_KEY_AGE}" ] || { echo "✗ release.dp signing key not found: ${AGE_KEY_AGE}" >&2; exit 1; }
        SHRED_FILE="$(mktemp "${TMPDIR:-/tmp}/burrowee-relay-key.XXXXXX")"
        chmod 600 "${SHRED_FILE}"
        age -d -i "${AGE_IDENTITY}" -o "${SHRED_FILE}" "${AGE_KEY_AGE}" \
            || { echo "✗ failed to decrypt ${AGE_KEY_AGE}" >&2; exit 1; }
        sign_key="${SHRED_FILE}"
    fi
    ( cd "${latest_stage}" && minisign -S -s "${sign_key}" -m SHA256SUMS.txt \
        -t "burrowee relay ${stamp}" >/dev/null )
    shred_key

    echo "Relay latest.* set + SHA256SUMS.txt + .minisig staged under ${latest_stage}:"
    # shellcheck disable=SC2012
    ( cd "${latest_stage}" && ls -1 latest.*.zip SHA256SUMS.txt SHA256SUMS.txt.minisig | sed 's/^/    /' )

    if [ "${DRY_RUN}" = 1 ]; then
        echo "→ would: publish-relay to R2 under relay/${stamp}/"
        for pair in "${TARGETS[@]}"; do read -r os arch <<<"${pair}"; echo "    relay/${stamp}/latest.${os}-${arch}.zip"; done
        echo "    relay/${stamp}/SHA256SUMS.txt"
        echo "    relay/${stamp}/SHA256SUMS.txt.minisig"
        echo "→ would: marker commit [RELEASED: relay] ${stamp} (private)"
        echo "→ would: register_staged relay ${stamp} (console catalog, R2 keys)"
        echo "✓ dry-run distribute-only relay: no real writes (R2/git)"
        return 0
    fi

    command -v jq >/dev/null 2>&1 || { echo "✗ required tool not found: jq" >&2; exit 1; }
    build_register_helper
    # (3) upload latest.* + SHA256SUMS + minisig to R2 under relay/<stamp>/.
    "${REGISTER_BIN}" publish-relay --stamp "${stamp}" --from-dir "${latest_stage}"
    echo "→ relay R2 retention (report only — run prune --comp relay --execute to apply):"
    "${REGISTER_BIN}" prune --comp relay || true
    # (4) marker commit (private — no gh release / no git tag).
    git add "versions/${comp}"
    git commit -m "[RELEASED: ${comp}] $(date -u +%Y-%m-%d) ${stamp} (private)"
    # (5) console catalog row (LAST) — relay uses R2 keys, not GitHub URLs.
    # register_staged records the dispatcher stamp bundled into the zip; resolve
    # it here (the public distribute_only sets DISP_STAMP the same way).
    DISP_STAMP="$(resolve_disp_stamp)"
    register_staged "${comp}" "${stamp}" "${semver}" "${latest_stage}" "${src}"
    echo "✓ distributed relay ${stamp} (private, R2 relay/${stamp}/)"
}

distribute_only() {
    local comp="$1" stamp="$2"
    case "${comp}" in
        cli|gateway|edge|agent) ;;
        relay) distribute_relay "${stamp}"; return $? ;;   # private R2 flow (no GitHub Release)
        *) echo "✗ unknown component: ${comp}" >&2; exit 1 ;;
    esac

    local stage="${REPO_ROOT}/dist/${stamp}"
    [ -d "${stage}" ] || { echo "✗ staged dir missing: ${stage} (run rkit build first)" >&2; exit 1; }
    for f in SHA256SUMS.txt SHA256SUMS.txt.minisig; do
        [ -f "${stage}/${f}" ] || { echo "✗ missing ${f} in ${stage} (rkit build must produce it)" >&2; exit 1; }
    done

    local src semver
    src="$(src_for "${comp}")"                    # reuse SRC_<comp> resolution
    [ -d "${src}" ] || { echo "✗ ${comp} source worktree missing: ${src}" >&2; exit 1; }
    semver="$(SRC_DIR="${src}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --semver)"

    if [ "${DRY_RUN}" = 1 ]; then
        echo "→ would: gh release create ${comp}/${stamp} (GitHub Release, public) via ghp"
        echo "→ would: gen-bootstraps.sh (regenerate ${comp}/install.sh + ${comp}/preflight.sh)"
        echo "→ would: scp install.sh/preflight.sh/burrowee-release.pub/site/index.html/skills to ${RELEASE_HOST}:${STATIC_DIR}/${comp}/ (self-hosting upload)"
        echo "→ would: marker commit [RELEASED: ${comp}] ${stamp}"
        echo "→ would: register_staged ${comp} ${stamp} (console catalog)"
        echo "→ would: GitHub release retention report (prune-releases.sh, dry-run)"
        echo "✓ dry-run distribute-only: no real writes"
        return 0
    fi

    # jq preflight: register_staged's json_escape shells out to `jq -Rs`; fail
    # friendly here rather than mid-register_staged. Inlined (same check/message
    # as the shared need() helper, not a call to it) — need() is defined further
    # down the script, past this DISTRIBUTE_ONLY dispatch branch, which already
    # returns (see the `if [ "${DISTRIBUTE_ONLY}" = 1 ]` block below) before
    # execution ever reaches need()'s definition.
    command -v jq >/dev/null 2>&1 || { echo "✗ required tool not found: jq" >&2; exit 1; }

    [ -d "${SRC_DISPATCHER}" ] || { echo "✗ dispatcher source worktree missing: ${SRC_DISPATCHER}" >&2; exit 1; }
    DISP_STAMP="$(resolve_disp_stamp)"
    if command -v shasum >/dev/null 2>&1; then SHA256="shasum -a 256"
    elif command -v sha256sum >/dev/null 2>&1; then SHA256="sha256sum"
    else echo "✗ neither shasum nor sha256sum found" >&2; exit 1; fi
    build_register_helper

    # (1) tag + GitHub Release.
    gh_release_publish "${comp}" "${stamp}" "${stage}"

    # (2) regenerate bootstraps + refresh edge skills + scp the static surface —
    # mirrors do_release()'s self-hosting block verbatim so a distribute-only
    # cut actually updates release.burrowee.com, not just the GitHub Release.
    bash "${REPO_ROOT}/tools/gen-bootstraps.sh" >&2
    # Edge operator skills are OWNED by the edge repo; mirror them in from its
    # worktree on every release so the served copy can never drift from source.
    # (The cli + gateway skills are authored in THIS repo and are left untouched.)
    # EXCEPTION — burrowee-edge-{setup,install} are AGENT-flow skills authored in
    # THIS repo (commit 0aae670 folded the edge operator flow into the
    # `burrowee-agent edge …` next-action loop the entry skill / llms.txt /
    # burrowee.json route agents to). They intentionally supersede the edge repo's
    # operator copies, so the mirror must NEVER overwrite them — doing so silently
    # reverts the agent flow (as the 07-08 cut did in 1a6c716). Any OTHER
    # burrowee-edge-* skill the edge repo owns is still mirrored here. Fail loudly
    # if the edge source is gone — a stale snapshot must not ship silently.
    [ -d "${EDGE_SKILLS_SRC}" ] \
        || { echo "✗ edge skills source missing: ${EDGE_SKILLS_SRC} (set BURROWEE_SRC_EDGE)" >&2; exit 1; }
    mkdir -p "${REPO_ROOT}/skills"
    for d in "${EDGE_SKILLS_SRC}"/burrowee-edge-*; do
        [ -d "${d}" ] || continue
        case "$(basename "${d}")" in
            burrowee-edge-setup|burrowee-edge-install)
                echo "→ skip edge skill $(basename "${d}") — agent-flow copy owned by release repo (see 0aae670)" >&2
                continue ;;
        esac
        mkdir -p "${REPO_ROOT}/skills/$(basename "${d}")"
        cp "${d}/SKILL.md" "${REPO_ROOT}/skills/$(basename "${d}")/SKILL.md"
        echo "→ synced edge skill $(basename "${d}") from ${EDGE_SKILLS_SRC}" >&2
    done

    # shellcheck disable=SC2029  # ${STATIC_DIR}/${comp} are local, controlled values — expanding client-side into the remote command is intended.
    ssh "${RELEASE_HOST}" "mkdir -p '${STATIC_DIR}/${comp}'"
    scp -q "${REPO_ROOT}/${comp}/install.sh" "${RELEASE_HOST}:${STATIC_DIR}/${comp}/install.sh"
    # preflight.sh is a sibling static file the installer fetches before the trust
    # gate (sha256-pinned in install.sh). Ship it alongside install.sh.
    if [ -f "${REPO_ROOT}/${comp}/preflight.sh" ]; then
        scp -q "${REPO_ROOT}/${comp}/preflight.sh" "${RELEASE_HOST}:${STATIC_DIR}/${comp}/preflight.sh"
    fi
    if [ -f "${REPO_ROOT}/burrowee-release.pub" ]; then
        scp -q "${REPO_ROOT}/burrowee-release.pub" "${RELEASE_HOST}:${STATIC_DIR}/burrowee-release.pub"
    fi
    if [ -f "${REPO_ROOT}/site/index.html" ]; then
        scp -q "${REPO_ROOT}/site/index.html" "${RELEASE_HOST}:${STATIC_DIR}/index.html"
    fi
    for d in "${REPO_ROOT}/skills"/*/; do
        [ -d "${d}" ] || continue
        [ -f "${d}SKILL.md" ] || continue
        sk="$(basename "${d}")"
        # shellcheck disable=SC2029  # ${STATIC_DIR}/skills/${sk} are local, controlled values — expanding client-side into the remote command is intended.
        ssh "${RELEASE_HOST}" "mkdir -p '${STATIC_DIR}/skills/${sk}'"
        scp -q "${d}SKILL.md" "${RELEASE_HOST}:${STATIC_DIR}/skills/${sk}/SKILL.md"
    done

    # (3) marker commit.
    git add "versions/${comp}" "${comp}/install.sh" "${comp}/preflight.sh"
    [ -d "${REPO_ROOT}/skills" ] && git add skills 2>/dev/null || true
    git commit -m "[RELEASED: ${comp}] $(date -u +%Y-%m-%d) ${stamp}"

    # (4) register staged row in the console catalog — LAST, only after the
    # GitHub Release + self-hosting upload + marker commit all succeeded, so
    # the catalog never advertises artifacts that aren't actually live.
    register_staged "${comp}" "${stamp}" "${semver}" "${stage}" "${src}" "${comp}/${stamp}"

    echo
    echo "→ GitHub release retention (dry-run — run prune-releases.sh --execute in the deploy phase to apply):"
    COMPONENTS="${comp}" bash "${REPO_ROOT}/tools/prune-releases.sh" || true

    echo "✓ distributed ${comp}/${stamp}"
    echo "  Release: https://github.com/${RELEASE_REPO}/releases/tag/${comp}/${stamp}"
}

# ---- decrypted-key shredder + its trap --------------------------------------
# MUST be registered BEFORE the DISTRIBUTE_ONLY dispatch below: distribute_relay
# also age-decrypts the real signing key, and it runs and exits from inside that
# dispatch. With the trap registered further down (past the dispatch) a minisign
# failure or a Ctrl-C during the relay signing step left the plaintext key on
# disk. Every path that decrypts the key assigns ${SHRED_FILE}, so this one
# overwrite-then-unlink implementation covers all of them.
SHRED_FILE=""
shred_key() {
    [ -n "${SHRED_FILE}" ] || return 0
    [ -f "${SHRED_FILE}" ] || return 0
    if command -v shred >/dev/null 2>&1; then
        shred -u "${SHRED_FILE}" 2>/dev/null || rm -f "${SHRED_FILE}"
    else
        # no shred on macOS — overwrite then unlink. The decrypted signing key
        # must NEVER survive on disk un-overwritten (rm alone leaves it
        # recoverable), so a dd failure aborts loudly instead of silently
        # rm'ing the still-readable key.
        if ! dd if=/dev/urandom of="${SHRED_FILE}" bs=1k count=2 conv=notrunc 2>/dev/null; then
            rm -f "${SHRED_FILE}"
            echo "✗ FAILED to overwrite decrypted signing key at ${SHRED_FILE} — it may be recoverable; investigate" >&2
            exit 1
        fi
        rm -f "${SHRED_FILE}"
    fi
    SHRED_FILE=""
}
trap shred_key EXIT INT TERM

# Where this cut (or a --distribute-only publish) is allowed to build from
# (tools/cut_origin.sh): the registry main folder, primary worktree, on main,
# clean, and equal to origin/main — for every tree read or written. --dry-run
# reports instead of failing. Computed once here so both entry points below
# (distribute-only and the full cut) share the same mode.
CUT_ORIGIN_MODE=strict
[ "${DRY_RUN}" = 1 ] && CUT_ORIGIN_MODE=report

if [ "${DISTRIBUTE_ONLY}" = 1 ]; then
    # rkit build staged the bump; both files ride the [RELEASED] marker commit
    # distribute_only makes (release.sh:868-870, `git commit` with no pathspec
    # commits the whole index). Without this the two-step path deadlocks: staged
    # counts as dirty, and committing makes the repo ahead of origin/main.
    # mapfile/readarray is a bash-4+ builtin, not present in macOS's system
    # bash 3.2 that this script runs under (see tools/cut_origin.test.sh's own
    # note on the same constraint) — build the array with a read loop instead.
    RELEASE_REPO_STAGED_OK=()
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        RELEASE_REPO_STAGED_OK+=("${line}")
    done <<EOF
$(staged_tolerance_for 1 "${DIST_COMP}")
EOF

    # distribute_only always mirrors edge skills (EDGE_SKILLS_SRC=${SRC_EDGE}/skills)
    # into the release repo regardless of which component is being distributed
    # (a stale edge tree would publish stale skills alongside a fresh cli/gateway/
    # agent/edge release), so edge is asserted alongside the requested component.
    # distribute_relay is the private R2 flow — it never reads edge.
    if [ "${DIST_COMP}" = relay ]; then
        assert_cut_origins "${CUT_ORIGIN_MODE}" relay || exit 1
    elif [ "${DIST_COMP}" = edge ]; then
        assert_cut_origins "${CUT_ORIGIN_MODE}" edge || exit 1
    else
        assert_cut_origins "${CUT_ORIGIN_MODE}" "${DIST_COMP}" edge || exit 1
    fi
    distribute_only "${DIST_COMP}" "${DIST_STAMP}"
    exit 0
fi

# components to cut
if [ "${WHAT}" = all ]; then COMPONENTS=(cli gateway edge agent); else COMPONENTS=("${WHAT}"); fi

# Every do_release() (i.e. every non-relay component) mirrors the edge skills
# (EDGE_SKILLS_SRC=${SRC_EDGE}/skills) unconditionally, so the edge tree is
# read even when it is not the component being cut. Asserted here rather than
# inside do_release so a stale edge tree fails the cut before anything is
# built, and only once when edge IS already in COMPONENTS. do_release_relay
# never reads edge, so a relay-only cut (the only way COMPONENTS can be just
# "relay" — WHAT is a single token) does not assert it needlessly. Surfaced
# ahead of the DP_DIR/signing-key/ghp/ssh pre-flight below so a bad source
# tree is reported first, not masked by an unrelated environment error.
CUT_ORIGIN_COMPS=("${COMPONENTS[@]}")
needs_edge=0
for c in "${COMPONENTS[@]}"; do
    [ "${c}" = relay ] || { needs_edge=1; break; }
done
if [ "${needs_edge}" = 1 ]; then
    case " ${COMPONENTS[*]} " in
        *" edge "*) ;;
        *) CUT_ORIGIN_COMPS+=(edge) ;;
    esac
fi
assert_cut_origins "${CUT_ORIGIN_MODE}" "${CUT_ORIGIN_COMPS[@]}" || exit 1

# ---- pre-flight -------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "✗ required tool not found: $1" >&2; exit 1; }; }
need zip
need unzip
need minisign
need jq   # json_escape (console-register payload) builds JSON via `jq -Rs`, not hand-rolled sed
command -v "${GO_BIN}" >/dev/null 2>&1 || { echo "✗ go not found (tried '${GO_BIN}')" >&2; exit 1; }

# Apple-sign mode: resolve the shared Modernech signer + confirm the identity is
# installed. Exported so tools/build.sh signs the darwin bins with the same tool;
# darwin zips are notarized below after assembly.
if [ -n "${APPLE_SIGN}" ]; then
    [ "$(uname -s)" = Darwin ] || { echo "✗ --apple requires a macOS build host" >&2; exit 1; }
    SIGN_BIN="${MODERNECH_SIGN:-modernech-sign}"
    command -v "${SIGN_BIN}" >/dev/null 2>&1 || SIGN_BIN="${HOME}/bin/modernech-sign"
    command -v "${SIGN_BIN}" >/dev/null 2>&1 \
        || { echo "✗ --apple set but modernech-sign not found on PATH or ~/bin" >&2; exit 1; }
    # Assert the identity is REACHABLE, not that it sits in the keychain: since
    # 2026-07-17 modernech-sign's default `auto` mode prefers its rcodesign
    # disk-key backend (decrypting the age-sealed .p12 at sign time), where the
    # identity never enters a keychain at all. A keychain-presence assertion is
    # therefore wrong under the mode we normally sign in, and it hard-failed every
    # cut from a harness/SSH session, whose macOS security session is detached (its
    # keychain search list is System-only, so the login keychain is unreachable).
    # modernech-sign stays the source of truth for WHICH backend runs; this only
    # fails fast when neither backend could possibly work. Both predicates live in
    # tools/apple_sign.sh — resolve_sign_identity refuses an EMPTY identity (the
    # old inline `grep -q "$("${SIGN_BIN}" id)"` degraded to `grep -q ""` and
    # passed vacuously), and sign_identity_reachable does the literal match.
    SIGN_ID="$(resolve_sign_identity "${SIGN_BIN}")" || exit 1
    if ! sign_identity_reachable "${SIGN_ID}"; then
        echo "✗ Developer ID identity unreachable: ${SIGN_ID}" >&2
        echo "  rcodesign (disk-key backend) is not on PATH and the identity is not in this session's keychain." >&2
        echo "  Install rcodesign (cargo install apple-codesign) or sign from a GUI Terminal session." >&2
        exit 1
    fi
    export MODERNECH_SIGN="${SIGN_BIN}"
    echo "→ --apple: Developer ID signing + notarization via ${SIGN_BIN}" >&2
fi

# sha256 tool (shasum on mac, sha256sum on linux)
if command -v shasum >/dev/null 2>&1; then
    SHA256="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
    SHA256="sha256sum"
else
    echo "✗ neither shasum nor sha256sum found" >&2; exit 1
fi

if [ "${DRY_RUN}" != 1 ]; then
    need age
    [ -f "${AGE_KEY_AGE}" ] \
        || { echo "✗ release.dp signing key not found: ${AGE_KEY_AGE}" >&2; exit 1; }
    # relay-only runs publish to R2 (no scp/ssh); public component runs need ghp + ssh.
    if [ "${WHAT}" != relay ]; then
        need ghp
        [ -x "${GHP}" ] || { echo "✗ ghp wrapper not found at ${GHP}" >&2; exit 1; }
        "${GHP}" repo view "${RELEASE_REPO}" --json name >/dev/null 2>&1 \
            || { echo "✗ ghp cannot access ${RELEASE_REPO} — check gh.account + auth" >&2; exit 1; }
        ssh -o BatchMode=yes -o ConnectTimeout=5 "${RELEASE_HOST}" 'true' 2>/dev/null \
            || { echo "✗ cannot ssh to ${RELEASE_HOST}" >&2; exit 1; }
    fi
fi

# CVE hard gate (public releases only): scan every module we're about to build.
# Runs before the first build so a vulnerable cut never produces a binary.
vulncheck_gate

# revert_dispatcher_version restores versions/burrowee (and versions/burrowee.stamp)
# when a real release bumped/wrote them (below) but died before the first
# component's marker commit staged them in. On success the bump/stamp is
# committed (no staged diff) → this is a no-op; dry-runs never bump or write
# the stamp → also a no-op. It is deliberately NOT part of the shred_key trap
# above: --distribute-only never bumps the dispatcher version or writes the
# stamp, so adding this to that path could only touch an operator's unrelated
# staging.
#
# versions/burrowee.stamp is folded in here (rather than a separate trap
# handler) because it's the same failure class as the semver bump: resolve_disp_stamp
# (defined above, near SRC_DISPATCHER) writes + `git add`s it as soon as it
# mints a fresh stamp, but that's only ever committed at the [RELEASED]
# marker — a cut that aborts in between must not leave a staged stamp dated
# today for the next unchanged-source cut to wrongly reuse.
revert_dispatcher_version() {
    git -C "${REPO_ROOT}" diff --cached --quiet versions/burrowee 2>/dev/null || {
        git -C "${REPO_ROOT}" restore --staged versions/burrowee 2>/dev/null || true
        git -C "${REPO_ROOT}" checkout -- versions/burrowee 2>/dev/null || true
    }
    git -C "${REPO_ROOT}" diff --cached --quiet versions/burrowee.stamp 2>/dev/null || {
        git -C "${REPO_ROOT}" restore --staged versions/burrowee.stamp 2>/dev/null || true
        git -C "${REPO_ROOT}" checkout -- versions/burrowee.stamp 2>/dev/null || true
    }
}
trap 'shred_key; revert_dispatcher_version' EXIT INT TERM

# ---- resolve the signing key ------------------------------------------------
# Sets SIGN_KEY. For the real key we age-decrypt into the chmod-600 ${SHRED_FILE}
# tmpfile that the trap registered above the DISTRIBUTE_ONLY dispatch shreds.
# The TEST key is used as-is for --dry-run.
resolve_sign_key() {
    if [ -n "${SIGN_KEY:-}" ]; then
        [ -f "${SIGN_KEY}" ] || { echo "✗ SIGN_KEY not found: ${SIGN_KEY}" >&2; exit 1; }
        echo "→ signing with provided SIGN_KEY: ${SIGN_KEY}" >&2
        return 0
    fi
    if [ "${DRY_RUN}" = 1 ]; then
        SIGN_KEY="${REPO_ROOT}/tools/testkeys/test.key"
        [ -f "${SIGN_KEY}" ] \
            || { echo "✗ TEST signing key missing: ${SIGN_KEY} (run Phase 5a: minisign -G ...)" >&2; exit 1; }
        echo "→ dry-run: signing with the TEST key (${SIGN_KEY})" >&2
        return 0
    fi
    # real release: decrypt the age-sealed signing key to a 600 tmpfile.
    [ -f "${AGE_IDENTITY}" ] || { echo "✗ age identity not found: ${AGE_IDENTITY}" >&2; exit 1; }
    SHRED_FILE="$(mktemp "${TMPDIR:-/tmp}/burrowee-release-key.XXXXXX")"
    chmod 600 "${SHRED_FILE}"
    age -d -i "${AGE_IDENTITY}" -o "${SHRED_FILE}" "${AGE_KEY_AGE}" \
        || { echo "✗ failed to decrypt ${AGE_KEY_AGE}" >&2; exit 1; }
    SIGN_KEY="${SHRED_FILE}"
    echo "→ signing with the real key (decrypted from release.dp)" >&2
}
resolve_sign_key

# ---- build the register helper (host-only; validates it compiles) ------------
build_register_helper

# ---- edge console pubkey ----------------------------------------------------
# Precedence: BURROWEE_CONSOLE_PUB (or legacy BURROWEE_CLOUD_PUB) override, else
# config/console-pub.hex. The override lets a dev release bake a non-prod key.
console_pub_hex() {
    if [ -n "${BURROWEE_CONSOLE_PUB:-}" ]; then printf '%s' "${BURROWEE_CONSOLE_PUB}"; return; fi
    if [ -n "${BURROWEE_CLOUD_PUB:-}" ]; then
        echo "⚠ deprecated env var BURROWEE_CLOUD_PUB — use BURROWEE_CONSOLE_PUB" >&2
        printf '%s' "${BURROWEE_CLOUD_PUB}"; return
    fi
    grep -v '^#' "${REPO_ROOT}/config/console-pub.hex" | grep -v '^[[:space:]]*$' | head -n1
}

# ---- dispatcher version + build cache (one build per os/arch, reused) --------
# The `burrowee` dispatcher is built once per run and bundled into EVERY
# component zip. It is a zero-logic exec table, so its binary changes ONLY when
# the burrowee repo source changes — which is rare. The cut therefore does NOT
# auto-bump it: resolve_disp_stamp() (defined above, near SRC_DISPATCHER)
# reuses the recorded versions/burrowee.stamp verbatim — date frozen — when
# the dispatcher source is unchanged, so a routine component cut mints no
# dispatcher version churn.
#
# When (and only when) the dispatcher source actually changed, bump it MANUALLY
# before the cut, from the release repo root: `bash tools/version.sh burrowee
# --bump-patch` (no SRC_DIR needed — only --stamp reads it). That stages
# versions/burrowee; resolve_disp_stamp() then mints a fresh stamp (its
# recorded sha8/semver no longer match) and records it to
# versions/burrowee.stamp, which rides the first component's [RELEASED]
# marker commit (`git commit` with no pathspec commits all staged files).
DISP_STAMP="$(resolve_disp_stamp)"
DISP_DIR="${REPO_ROOT}/dist/.dispatcher/${DISP_STAMP}"

# THE CACHE IS SIGNING-AWARE, and has to be. Its key is the dispatcher SOURCE —
# DISP_STAMP — which says nothing about signing mode, and BOTH modes write into
# the same directory. `--dry-run`, the documented way to validate a cut before
# making it, leaves an AD-HOC signed dispatcher under that key; the plain
# `if [ -x "$out/burrowee" ]; then return 0; fi` cache then handed that binary to
# the --public cut minutes later, which copied it into every component zip as
# `burrowee`. Apple's notary rejected the edge zip for that exact file: not
# Developer-ID signed, no secure timestamp, no hardened runtime. So the safe
# pre-cut step POISONED the real cut.
#
# Verified rather than partitioned by mode: a mode-suffixed directory would fix
# this one path and still trust whatever is found there, while
# developer_id_signed() (tools/apple_sign.sh) rejects a wrong-mode artifact
# whatever produced it — a hand-copied binary, an interrupted signer, a partial
# rebuild. Fail closed: unsigned, ad-hoc, or UNDETERMINABLE all rebuild.
build_dispatcher() {
    # build_dispatcher <os> <arch> — idempotent; populates $DISP_DIR/<os>-<arch>/burrowee
    local os="$1" arch="$2" out="${DISP_DIR}/$1-$2"
    if [ -x "${out}/burrowee" ]; then
        # Off darwin, and in every non-Apple mode, the cache means what it always
        # meant: one build per target per run.
        if [ -z "${APPLE_SIGN}" ] || [ "${os}" != darwin ]; then return 0; fi
        if developer_id_signed "${out}/burrowee"; then return 0; fi
        echo "→ dispatcher cache ${DISP_STAMP}/${os}-${arch} is not Developer-ID signed (an" >&2
        echo "  earlier non-Apple build or --dry-run left it) — rebuilding and re-signing" >&2
        rm -f "${out}/burrowee"
    fi
    mkdir -p "${out}"
    COMP=burrowee SRC_DIR="${SRC_DISPATCHER}" TARGETOS="${os}" TARGETARCH="${arch}" \
        STAMP="${DISP_STAMP}" OUT_DIR="${out}" GO_BIN="${GO_BIN}" \
        bash "${REPO_ROOT}/tools/build.sh" >&2
}

# ---- relay private-publish ---------------------------------------------------
do_release_relay() {
    local src="${SRC_RELAY}"
    local comp=relay
    local bins; bins="$(bins_for "${comp}")"

    echo
    echo "=== burrowee relay release (private) ==="

    # (1) stamp — reuse the recorded stamp verbatim (no bump) when relay's
    # source is unchanged since its last cut and the default patch bump is in
    # effect; else bump per BUMP_KIND and mint a fresh stamp. See
    # resolve_comp_stamp() above.
    local old_semver new_semver stamp
    old_semver="$(SRC_DIR="${src}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --semver)"
    stamp="$(resolve_comp_stamp "${comp}" "${src}")"
    new_semver="$(SRC_DIR="${src}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --semver)"

    revert_relay_version() {
        git restore --staged "versions/${comp}" 2>/dev/null || true
        git checkout -- "versions/${comp}" 2>/dev/null || true
        git restore --staged "versions/${comp}.stamp" 2>/dev/null || true
        git checkout -- "versions/${comp}.stamp" 2>/dev/null || true
    }
    # ERR INT TERM (not just ERR): a Ctrl-C/SIGTERM after resolve_comp_stamp
    # bumped versions/${comp} must revert it too — mirrors resolve_disp_stamp's
    # dispatcher revert already running on EXIT INT TERM (line ~946). The EXIT
    # trap registered there (shred_key; revert_dispatcher_version) is untouched
    # by this signal-scoped override, so the dispatcher side of cleanup still
    # fires at actual process exit either way.
    trap 'revert_relay_version; shred_key' ERR INT TERM

    if [ "${old_semver}" != "${new_semver}" ]; then
        echo "Bump    : ${BUMP_KIND} (${old_semver} → ${new_semver})"
    elif [ "${DRY_RUN}" = 1 ]; then
        # dry-run never bumps regardless of whether the source changed, so
        # old==new here doesn't necessarily mean "unchanged" — resolve_comp_stamp
        # may still have minted a fresh (changed-source) stamp above.
        echo "Bump    : (dry-run — not bumped; semver ${new_semver})"
    else
        echo "Bump    : reuse (unchanged, no bump) — ${new_semver}"
    fi
    echo "Stamp   : ${stamp}"
    echo "Source  : ${src} @ $(git -C "${src}" rev-parse --short=8 HEAD)"
    echo "Disp    : ${DISP_STAMP}  (not auto-bumped — bump versions/burrowee manually if the dispatcher source changed)"
    echo "Dry-run : ${DRY_RUN}"

    local stage="${REPO_ROOT}/dist/${stamp}"
    rm -rf "${stage}"
    mkdir -p "${stage}"

    # (2) per-target build + assemble + zip.
    local zips=() pair os arch out_bins assemble asset b s
    for pair in "${TARGETS[@]}"; do
        read -r os arch <<<"${pair}"
        out_bins="${stage}/.bins-${os}-${arch}"
        mkdir -p "${out_bins}"

        # dispatcher for this target (built once, reused) — bundled like the public comps.
        build_dispatcher "${os}" "${arch}"

        # relay binaries: build.sh emits all three (serve + cli + updater); the cli
        # and updater get console identity baked (console_pub_hex from
        # config/console-pub.hex). The serve binary gets only -X main.version.
        COMP="${comp}" SRC_DIR="${src}" TARGETOS="${os}" TARGETARCH="${arch}" \
            STAMP="${stamp}" OUT_DIR="${out_bins}" GO_BIN="${GO_BIN}" \
            CONSOLE_PUB_HEX="$(console_pub_hex)" \
            bash "${REPO_ROOT}/tools/build.sh" >&2

        # assemble: four binaries (3 relay-tree + dispatcher) + the three relay
        # scripts copied from the relay source. The full installer install.sh is the
        # zip's entrypoint; update.sh + updater.update.sh ride alongside it.
        assemble="${stage}/burrowee-${comp}-${os}-${arch}"
        rm -rf "${assemble}"
        mkdir -p "${assemble}"
        # shellcheck disable=SC2086  # ${bins} is an intentional space-list from bins_for(); word-splitting is the point.
        for b in ${bins}; do cp "${out_bins}/${b}" "${assemble}/${b}"; done
        cp "${DISP_DIR}/${os}-${arch}/burrowee" "${assemble}/burrowee"
        for s in install.sh update.sh updater.update.sh; do
            [ -f "${src}/${s}" ] || { echo "✗ relay script missing in source: ${src}/${s}" >&2; exit 1; }
            cp "${src}/${s}" "${assemble}/${s}"
            chmod 0755 "${assemble}/${s}"
        done

        # Pre-assembly signing gate: prove every Mach-O in the payload is
        # Developer-ID signed BEFORE it is zipped. Notarization below catches the
        # same thing, but only for darwin, only over the wire, and only after
        # every target is built — and --apple without --public never notarizes at
        # all. See assert_payload_developer_id_signed in tools/apple_sign.sh.
        if [ -n "${APPLE_SIGN}" ]; then
            assert_payload_developer_id_signed "${assemble}" "${os}" || exit 1
        fi

        asset="burrowee-${comp}-${os}-${arch}.zip"
        rm -f "${stage}/${asset}"
        ( cd "${assemble}" && zip -j -q "${stage}/${asset}" ./* )

        # Apple-sign mode: notarize the darwin zips (binaries were Developer ID
        # signed by build.sh). Submitting doesn't alter the zip, so the latest.*
        # copies below + their SHA256SUMS/minisig still cover these exact bytes.
        # Bare-binary zips can't be stapled — the ticket lives in Apple's online
        # DB. linux: skip.
        if [ -n "${APPLE_SIGN}" ] && [ "${os}" = darwin ]; then
            "${SIGN_BIN}" notarize "${stage}/${asset}" >&2
        fi

        zips+=("${asset}")
        rm -rf "${out_bins}"
    done

    # (3) sums + sign over the LATEST-NAMED set.
    # We name the zips as latest.<os>-<arch>.zip so the gate-served paths are
    # stable filenames the installer can hard-code:
    #   /relay/release/latest.darwin-arm64.zip, etc.
    # We also archive a copy under <stamp>/ for the prune-to-3 retention.
    local latest_stage="${REPO_ROOT}/dist/${stamp}/.latest"
    mkdir -p "${latest_stage}"
    for pair in "${TARGETS[@]}"; do
        read -r os arch <<<"${pair}"
        cp "${stage}/burrowee-${comp}-${os}-${arch}.zip" \
           "${latest_stage}/latest.${os}-${arch}.zip"
    done
    # SHA256SUMS over the latest.* filenames (what the installer verifies).
    # shellcheck disable=SC2086
    ( cd "${latest_stage}" && ${SHA256} latest.*.zip | sort > SHA256SUMS.txt )
    ( cd "${latest_stage}" && minisign -S -s "${SIGN_KEY}" -m SHA256SUMS.txt \
        -t "burrowee relay ${stamp}" >/dev/null )

    echo "Built ${#zips[@]} zips + latest.* set + SHA256SUMS.txt + SHA256SUMS.txt.minisig:"
    # shellcheck disable=SC2012
    ( cd "${latest_stage}" && ls -1 latest.*.zip SHA256SUMS.txt SHA256SUMS.txt.minisig | sed 's/^/    /' )

    if [ "${DRY_RUN}" = 1 ]; then
        # Print the would-upload plan (R2 keys, no scp).
        echo ""
        echo "✓ dry-run relay: would upload to R2 under relay/${stamp}/"
        echo "  R2 keys:"
        for pair in "${TARGETS[@]}"; do
            read -r os arch <<<"${pair}"
            echo "    relay/${stamp}/latest.${os}-${arch}.zip"
        done
        echo "    relay/${stamp}/SHA256SUMS.txt"
        echo "    relay/${stamp}/SHA256SUMS.txt.minisig"
        echo "(artifacts under ${latest_stage}/; version bump reverted; no scp)"
        # (9) dry-run registration preview.
        register_staged "${comp}" "${stamp}" "${new_semver}" "${latest_stage}" "${src}"
        revert_relay_version
        trap shred_key ERR INT TERM
        return 0
    fi

    # (4) non-dry-run: upload relay artifacts to R2 under relay/<stamp>/.
    # Uses the register tool's publish-relay subcommand which reads R2 creds from
    # ~/.burrowee/release/config.toml + r2.key and verifies sha256 before upload.
    # No scp, no ssh to the release host.
    "${REGISTER_BIN}" publish-relay \
        --stamp "${stamp}" \
        --from-dir "${latest_stage}"

    # (4b) retention (dry-run): report relay R2 prefixes now over keep=3. The
    # destructive drain (prune --comp relay --execute) is a deploy-phase step.
    echo
    echo "→ relay R2 retention (dry-run — run prune --comp relay --execute in the deploy phase to apply):"
    "${REGISTER_BIN}" prune --comp relay || true

    # marker commit (no gh release / no git tag)
    git add "versions/${comp}"
    git commit -m "[RELEASED: ${comp}] $(date -u +%Y-%m-%d) ${stamp} (private)"

    # (9) register staged row in the console catalog.
    register_staged "${comp}" "${stamp}" "${new_semver}" "${latest_stage}" "${src}"

    echo "✓ released relay ${stamp} (private, R2 relay/${stamp}/)"
    trap shred_key ERR INT TERM
}

# ---- per-component release --------------------------------------------------
do_release() {
    local comp="$1"
    local src; src="$(src_for "${comp}")"
    local bins; bins="$(bins_for "${comp}")"

    echo
    echo "=== burrowee ${comp} release ==="

    # (1) stamp — reuse the recorded stamp verbatim (no bump) when ${comp}'s
    # source is unchanged since its last cut and the default patch bump is in
    # effect; else bump per BUMP_KIND and mint a fresh stamp. See
    # resolve_comp_stamp() above.
    local old_semver new_semver stamp
    old_semver="$(SRC_DIR="${src}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --semver)"
    stamp="$(resolve_comp_stamp "${comp}" "${src}")"
    new_semver="$(SRC_DIR="${src}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --semver)"

    # From here the versions/<comp>(.stamp) files may be modified. Any
    # failure (or the dry-run completion) reverts them.
    revert_version() {
        git restore --staged "versions/${comp}" 2>/dev/null || true
        git checkout -- "versions/${comp}" 2>/dev/null || true
        git restore --staged "versions/${comp}.stamp" 2>/dev/null || true
        git checkout -- "versions/${comp}.stamp" 2>/dev/null || true
    }
    # ERR INT TERM (not just ERR): a Ctrl-C/SIGTERM after resolve_comp_stamp
    # bumped versions/${comp} must revert it too — mirrors resolve_disp_stamp's
    # dispatcher revert already running on EXIT INT TERM (line ~946). The EXIT
    # trap registered there (shred_key; revert_dispatcher_version) is untouched
    # by this signal-scoped override, so the dispatcher side of cleanup still
    # fires at actual process exit either way.
    trap 'revert_version; shred_key' ERR INT TERM

    if [ "${old_semver}" != "${new_semver}" ]; then
        echo "Bump    : ${BUMP_KIND} (${old_semver} → ${new_semver})"
    elif [ "${DRY_RUN}" = 1 ]; then
        # dry-run never bumps regardless of whether the source changed, so
        # old==new here doesn't necessarily mean "unchanged" — resolve_comp_stamp
        # may still have minted a fresh (changed-source) stamp above.
        echo "Bump    : (dry-run — not bumped; semver ${new_semver})"
    else
        echo "Bump    : reuse (unchanged, no bump) — ${new_semver}"
    fi
    echo "Stamp   : ${stamp}"
    echo "Source  : ${src} @ $(git -C "${src}" rev-parse --short=8 HEAD)"
    echo "Disp    : ${DISP_STAMP}  (not auto-bumped — bump versions/burrowee manually if the dispatcher source changed)"
    echo "Dry-run : ${DRY_RUN}"

    local stage="${REPO_ROOT}/dist/${stamp}"
    rm -rf "${stage}"
    mkdir -p "${stage}"

    # (3) per-target build + assemble + zip.
    local zips=() pair os arch out_bins assemble asset b s update_scripts
    for pair in "${TARGETS[@]}"; do
        read -r os arch <<<"${pair}"
        out_bins="${stage}/.bins-${os}-${arch}"
        mkdir -p "${out_bins}"

        # (2) dispatcher for this target (built once, reused).
        build_dispatcher "${os}" "${arch}"

        # component bins
        if [ "${comp}" = edge ]; then
            COMP="${comp}" SRC_DIR="${src}" TARGETOS="${os}" TARGETARCH="${arch}" \
                STAMP="${stamp}" OUT_DIR="${out_bins}" GO_BIN="${GO_BIN}" \
                CONSOLE_PUB_HEX="$(console_pub_hex)" \
                bash "${REPO_ROOT}/tools/build.sh" >&2
        else
            COMP="${comp}" SRC_DIR="${src}" TARGETOS="${os}" TARGETARCH="${arch}" \
                STAMP="${stamp}" OUT_DIR="${out_bins}" GO_BIN="${GO_BIN}" \
                bash "${REPO_ROOT}/tools/build.sh" >&2
        fi

        # assemble: component bins + dispatcher + inner installer (→ install.sh)
        assemble="${stage}/burrowee-${comp}-${os}-${arch}"
        rm -rf "${assemble}"
        mkdir -p "${assemble}"
        # shellcheck disable=SC2086  # ${bins} is an intentional space-list of bin names from bins_for(); word-splitting is the point.
        for b in ${bins}; do cp "${out_bins}/${b}" "${assemble}/${b}"; done
        cp "${DISP_DIR}/${os}-${arch}/burrowee" "${assemble}/burrowee"
        cp "${REPO_ROOT}/inner/${comp}/install.sh" "${assemble}/install.sh"
        chmod 0755 "${assemble}/install.sh"

        # Cloud-push update scripts: the burrowee-<comp>-updater (and core's Phase-0
        # routing) run `sh ./update.sh` (service update) with cwd = the unzipped
        # bundle, so update.sh MUST ride in the payload alongside the bins. edge +
        # relay additionally self-update via `sh ./updater.update.sh`; gateway + cli
        # self-update in-process (UpgradeSelf binary swap), so they ship update.sh
        # ONLY — no updater.update.sh exists in their source. Copied from the
        # component source; without them a pushed update extracts + verifies but then
        # fails "cannot open ./update.sh". (Mirrors cmd/rkit/assemble.go extraPayload.)
        case "${comp}" in
            edge)        update_scripts="update.sh updater.update.sh" ;;
            gateway|cli) update_scripts="update.sh" ;;
            *)           update_scripts="" ;;
        esac
        # shellcheck disable=SC2086  # ${update_scripts} is an intentional space-list of script names; word-splitting is the point.
        for s in ${update_scripts}; do
            [ -f "${src}/${s}" ] || { echo "✗ ${comp} update script missing in source: ${src}/${s}" >&2; exit 1; }
            cp "${src}/${s}" "${assemble}/${s}"
            chmod 0755 "${assemble}/${s}"
        done

        # edge decoy covers (copied from the edge.web repo at package time).
        # EDGE_WEB is resolved once, near the top of this file, beside the
        # other REG_*/SRC_* trees, and asserted by assert_cut_origins — not
        # re-resolved here.
        if [ "${comp}" = edge ]; then
            mkdir -p "${assemble}/covers"
            cp "${EDGE_WEB}/admin.html" "${assemble}/covers/admin.html"
            cp "${EDGE_WEB}/login.html" "${assemble}/covers/default.html"
        fi

        # Pre-assembly signing gate — same assertion as the relay flow above; see
        # assert_payload_developer_id_signed in tools/apple_sign.sh. This is the
        # site that shipped the ad-hoc dispatcher Apple rejected.
        if [ -n "${APPLE_SIGN}" ]; then
            assert_payload_developer_id_signed "${assemble}" "${os}" || exit 1
        fi

        asset="burrowee-${comp}-${os}-${arch}.zip"
        rm -f "${stage}/${asset}"
        ( cd "${assemble}" && zip -j -q "${stage}/${asset}" ./* )
        # Edge payload carries covers/ — zip -j skips directories, so append them
        # recursively to preserve the covers/ path inside the zip.
        if [ "${comp}" = edge ]; then
            ( cd "${assemble}" && zip -r -q "${stage}/${asset}" covers/ )
        fi

        # Apple-sign mode: notarize the darwin zips (binaries were Developer ID
        # signed by build.sh). Submitting doesn't alter the zip, so the later
        # SHA256SUMS + minisign still cover these exact bytes. Bare-binary zips
        # can't be stapled — the ticket lives in Apple's online DB. linux: skip.
        if [ -n "${APPLE_SIGN}" ] && [ "${os}" = darwin ]; then
            "${SIGN_BIN}" notarize "${stage}/${asset}" >&2
        fi

        zips+=("${asset}")
        rm -rf "${out_bins}"
    done

    # (4) sums over the four zips.
    # shellcheck disable=SC2086  # ${SHA256} is an intentional space-split command string ("shasum -a 256" | "sha256sum"); word-splitting is the point.
    ( cd "${stage}" && ${SHA256} burrowee-"${comp}"-*.zip | sort > SHA256SUMS.txt )

    # (5) sign.
    ( cd "${stage}" && minisign -S -s "${SIGN_KEY}" -m SHA256SUMS.txt \
        -t "burrowee ${comp} ${stamp}" >/dev/null )

    echo "Built ${#zips[@]} zips + SHA256SUMS.txt + SHA256SUMS.txt.minisig:"
    # shellcheck disable=SC2012  # cosmetic listing of our own controlled asset names (no untrusted filenames); ls keeps the plain one-per-line format.
    ( cd "${stage}" && ls -1 burrowee-"${comp}"-*.zip SHA256SUMS.txt SHA256SUMS.txt.minisig | sed 's/^/    /' )

    if [ "${DRY_RUN}" = 1 ]; then
        echo "✓ dry-run ${comp}: artifacts under ${stage}/ (version bump reverted; no tag/release/scp)"
        # (9) dry-run registration preview (uses the dry-run stamp for URLs).
        local dry_tag="${comp}/${stamp}"
        register_staged "${comp}" "${stamp}" "${new_semver}" "${stage}" "${src}" "${dry_tag}"
        revert_version
        trap shred_key ERR INT TERM
        return 0
    fi

    # (6) tag + GitHub Release.
    local tag="${comp}/${stamp}"
    gh_release_publish "${comp}" "${stamp}" "${stage}"

    # Past the tag/release — clear the version-revert trap.
    trap shred_key ERR INT TERM

    # (7) regenerate bootstraps + refresh edge skills + scp the static surface.
    bash "${REPO_ROOT}/tools/gen-bootstraps.sh" >&2
    # Edge operator skills are OWNED by the edge repo; mirror them in from its
    # worktree on every release so the served copy can never drift from source.
    # (The cli + gateway skills are authored in THIS repo and are left untouched.)
    # EXCEPTION — burrowee-edge-{setup,install} are AGENT-flow skills authored in
    # THIS repo (commit 0aae670 folded the edge operator flow into the
    # `burrowee-agent edge …` next-action loop the entry skill / llms.txt /
    # burrowee.json route agents to). They intentionally supersede the edge repo's
    # operator copies, so the mirror must NEVER overwrite them — doing so silently
    # reverts the agent flow (as the 07-08 cut did in 1a6c716). Any OTHER
    # burrowee-edge-* skill the edge repo owns is still mirrored here. Fail loudly
    # if the edge source is gone — a stale snapshot must not ship silently.
    [ -d "${EDGE_SKILLS_SRC}" ] \
        || { echo "✗ edge skills source missing: ${EDGE_SKILLS_SRC} (set BURROWEE_SRC_EDGE)" >&2; exit 1; }
    mkdir -p "${REPO_ROOT}/skills"
    for d in "${EDGE_SKILLS_SRC}"/burrowee-edge-*; do
        [ -d "${d}" ] || continue
        case "$(basename "${d}")" in
            burrowee-edge-setup|burrowee-edge-install)
                echo "→ skip edge skill $(basename "${d}") — agent-flow copy owned by release repo (see 0aae670)" >&2
                continue ;;
        esac
        mkdir -p "${REPO_ROOT}/skills/$(basename "${d}")"
        cp "${d}/SKILL.md" "${REPO_ROOT}/skills/$(basename "${d}")/SKILL.md"
        echo "→ synced edge skill $(basename "${d}") from ${EDGE_SKILLS_SRC}" >&2
    done

    # shellcheck disable=SC2029  # ${STATIC_DIR}/${comp} are local, controlled values — expanding client-side into the remote command is intended.
    ssh "${RELEASE_HOST}" "mkdir -p '${STATIC_DIR}/${comp}'"
    scp -q "${REPO_ROOT}/${comp}/install.sh" "${RELEASE_HOST}:${STATIC_DIR}/${comp}/install.sh"
    # preflight.sh is a sibling static file the installer fetches before the trust
    # gate (sha256-pinned in install.sh). Ship it alongside install.sh.
    if [ -f "${REPO_ROOT}/${comp}/preflight.sh" ]; then
        scp -q "${REPO_ROOT}/${comp}/preflight.sh" "${RELEASE_HOST}:${STATIC_DIR}/${comp}/preflight.sh"
    fi
    if [ -f "${REPO_ROOT}/burrowee-release.pub" ]; then
        scp -q "${REPO_ROOT}/burrowee-release.pub" "${RELEASE_HOST}:${STATIC_DIR}/burrowee-release.pub"
    fi
    if [ -f "${REPO_ROOT}/site/index.html" ]; then
        scp -q "${REPO_ROOT}/site/index.html" "${RELEASE_HOST}:${STATIC_DIR}/index.html"
    fi
    for d in "${REPO_ROOT}/skills"/*/; do
        [ -d "${d}" ] || continue
        [ -f "${d}SKILL.md" ] || continue
        sk="$(basename "${d}")"
        # shellcheck disable=SC2029  # ${STATIC_DIR}/skills/${sk} are local, controlled values — expanding client-side into the remote command is intended.
        ssh "${RELEASE_HOST}" "mkdir -p '${STATIC_DIR}/skills/${sk}'"
        scp -q "${d}SKILL.md" "${RELEASE_HOST}:${STATIC_DIR}/skills/${sk}/SKILL.md"
    done

    # (8) marker commit.
    git add "versions/${comp}" "${comp}/install.sh" "${comp}/preflight.sh"
    [ -d "${REPO_ROOT}/skills" ] && git add skills 2>/dev/null || true
    git commit -m "[RELEASED: ${comp}] $(date -u +%Y-%m-%d) ${stamp}"

    # (9) register staged row in the console catalog.
    register_staged "${comp}" "${stamp}" "${new_semver}" "${stage}" "${src}" "${tag}"

    # (10) GitHub-release retention (dry-run): report tags now over keep=10. The
    # destructive drain (prune-releases.sh --execute) is a deploy-phase step.
    echo
    echo "→ GitHub release retention (dry-run — run prune-releases.sh --execute in the deploy phase to apply):"
    COMPONENTS="${comp}" bash "${REPO_ROOT}/tools/prune-releases.sh" || true

    echo "✓ released ${tag}"
    echo "  Release: https://github.com/${RELEASE_REPO}/releases/tag/${tag}"
}

for comp in "${COMPONENTS[@]}"; do
    if [ "${comp}" = relay ]; then
        do_release_relay
    else
        do_release "${comp}"
    fi
done

# leave dispatcher build cache for inspection on dry-run; clean on real release
if [ "${DRY_RUN}" != 1 ]; then rm -rf "${DISP_DIR}"; fi

echo
echo "✓ done (${WHAT}${DRY_RUN:+, dry-run=${DRY_RUN}})"

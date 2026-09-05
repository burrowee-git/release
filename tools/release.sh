#!/usr/bin/env bash
# release.sh — cut a signed Burrowee component release (cli | gateway | edge | agent).
#
# Usage:
#   bash tools/release.sh <cli|gateway|edge|agent|relay|all> [--channel stable|beta] [--apple] [--vulncheck|--public] [--dry-run] [--bump-minor|--bump-major|--keep-version] [--force]
#
# --channel beta: cut from the registry's beta worktree (<code>/beta,
#   see tools/release_origin.sh's beta_worktree_for) instead of the registry main
#   folder, stamp with the .beta. segment (tools/version.sh --channel beta), skip
#   GitHub entirely, and upload straight to R2 as a private, staged row — see
#   do_release()'s CHANNEL=beta branch below. Defaults to stable; --distribute-only
#   refuses --channel beta (that path re-publishes an already-staged GitHub
#   Release, which a beta cut never creates).
#
# --force: bump + mint a fresh stamp even when the component's source is
#   unchanged since its last cut (versions/<comp>.stamp's recorded sha8 +
#   semver both match). Without it, an unchanged component under the default
#   patch bump is REUSED verbatim (no bump, no date churn) — see
#   resolve_comp_stamp() below. Rare use case: re-shipping a component whose
#   bundled dispatcher changed but whose own source didn't.
#
# --keep-version: leave versions/<comp> EXACTLY as it is — no bump of any kind,
#   not even the default patch — while still minting a FRESH stamp over the
#   component's current commit. This deliberately REPUBLISHES a semver that is
#   already public: the new tag differs from the old one only in the stamp's
#   date/sha segments. Use it to re-cut a release whose PAYLOAD was wrong but
#   whose version number must not move. It refuses when the resulting stamp
#   already has a tag (semver + date + sha all equal — that is a real
#   collision), and refuses to combine with --bump-minor/--bump-major/--force,
#   every one of which moves the version this flag exists to pin.
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
#   BURROWEE_SRC_DISPATCHER See tools/release_origin.sh.
#   BURROWEE_SRC_RELAY
#   EDGE_WEB_DIR            edge.web tree (admin.html/login.html covers baked into
#                           the edge payload) — DRY-RUN ONLY; a real cut is refused
#                           unless the source is the registry main folder
#                           (<Brand>/edge.web/code/main), primary worktree, on
#                           main, clean, == origin/main. See tools/release_origin.sh.
#   BURROWEE_RELEASE_REPO   GitHub repo for releases (default burrowee-git/release)
#   BURROWEE_RELEASE_YES    skip the interactive minor/major bump confirm
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=tools/vulncheck.sh
source "${REPO_ROOT}/tools/vulncheck.sh"
# shellcheck source=tools/module_gate.sh
source "${REPO_ROOT}/tools/module_gate.sh"
# shellcheck source=tools/apple_sign.sh
source "${REPO_ROOT}/tools/apple_sign.sh"
# shellcheck source=tools/updater_pin.sh
source "${REPO_ROOT}/tools/updater_pin.sh"
# shellcheck source=tools/release_origin.sh
source "${REPO_ROOT}/tools/release_origin.sh"
# shellcheck source=tools/dispatcher_src.sh
source "${REPO_ROOT}/tools/dispatcher_src.sh"
# shellcheck source=tools/channels.sh
source "${REPO_ROOT}/tools/channels.sh"
# shellcheck source=tools/payload.sh
source "${REPO_ROOT}/tools/payload.sh"
# shellcheck source=tools/binmap.sh
source "${REPO_ROOT}/tools/binmap.sh"
# shellcheck source=tools/trustcomment.sh
source "${REPO_ROOT}/tools/trustcomment.sh"
# shellcheck source=tools/marker_commit.sh
source "${REPO_ROOT}/tools/marker_commit.sh"
# shellcheck source=tools/batch.sh
source "${REPO_ROOT}/tools/batch.sh"
# shellcheck source=tools/public_components.sh
source "${REPO_ROOT}/tools/public_components.sh"
# shellcheck source=tools/targets.sh
source "${REPO_ROOT}/tools/targets.sh"

# ---- go on PATH (the Burrowee per-dir hook strips /opt/homebrew/bin) ---------
GO_BIN="${GO_BIN:-go}"
command -v "${GO_BIN}" >/dev/null 2>&1 || GO_BIN=/opt/homebrew/bin/go
export GO_BIN

# ---- Component source trees. REG_* are the registry main folders — the ONLY
# paths a real cut may build from (tools/release_origin.sh, is_registry_source).
# SRC_* keep the documented BURROWEE_SRC_*/EDGE_WEB_DIR overrides, which
# assert_release_origin then accepts only under --dry-run: keeping the variables
# and refusing them is better than deleting them, because silently ignoring a
# variable an operator set is how a cut ends up building something nobody
# asked for.
#
# Defined ahead of build_register_helper/the publish intercept (below) — not in
# their original position further down the file — so the publish entry point
# can call assert_release_origins (and the src_for it depends on) before it does
# any work. Nothing here depends on the arg-parsing section that used to
# precede it: every value below reads only REPO_ROOT, BB, and the operator's
# environment.
BB="/Volumes/MacintoshED/Workstation/Coding/Burrowee"
REG_CLI="${BB}/cli/code/main"
REG_GATEWAY="${BB}/gateway/code/main"
REG_EDGE="${BB}/edge/code/main"
REG_EDGE_WEB="${BB}/edge.web/code/main"
REG_AGENT="${BB}/agent/code/main"
REG_DISPATCHER="${BB}/burrowee/code/main"
REG_RELAY="${BB}/relay/code/main"
REG_RELEASE="${BB}/release/code/main"

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
        dispatcher) printf '%s' "${REG_DISPATCHER}" ;;
        *) echo "registry_src_for: unknown component: $1" >&2; return 1 ;;
    esac
}

# src_for <comp> — the source worktree for a real cut/distribute of <comp>.
# Stable (default/unset CHANNEL): unchanged — SRC_<COMP> (a BURROWEE_SRC_*
# override, dry-run only, or the registry main folder). Beta: redirected to
# the registry's DERIVED beta worktree (beta_worktree_for, tools/release_origin.sh)
# — never a second, independently-configured path, so it cannot drift from the
# registry entry — UNLESS an override is set, which wins for both channels
# (dry-run only; assert_release_origin refuses it outside --dry-run). An
# override is detected by SRC_<COMP> disagreeing with REG_<COMP>: SRC_<COMP>
# already collapses "${BURROWEE_SRC_*:-${REG_*}}" once, near the top of this
# file, before CHANNEL is known.
src_for() {
    local comp="$1" reg cur
    case "${comp}" in
        cli)     reg="${REG_CLI}";     cur="${SRC_CLI}" ;;
        gateway) reg="${REG_GATEWAY}"; cur="${SRC_GATEWAY}" ;;
        edge)    reg="${REG_EDGE}";    cur="${SRC_EDGE}" ;;
        agent)   reg="${REG_AGENT}";   cur="${SRC_AGENT}" ;;
        relay)   reg="${REG_RELAY}";   cur="${SRC_RELAY}" ;;
        dispatcher) reg="${REG_DISPATCHER}"; cur="${SRC_DISPATCHER}" ;;
    esac
    if [ "${cur}" != "${reg}" ]; then
        printf '%s' "${cur}"                          # BURROWEE_SRC_* override
    elif [ "${CHANNEL:-stable}" = beta ]; then
        beta_worktree_for "${reg}"
    else
        printf '%s' "${reg}"
    fi
}

# Paths the RELEASE REPO may carry staged when the guard runs. Empty for every
# entry point except --distribute-only, which is preceded by an `rkit build` that
# stages the component's version + stamp so both ride the [RELEASED] marker commit.
# Forwarded to the release-repo assertion ONLY: no component tree ever gets it.
RELEASE_REPO_STAGED_OK=()

# assert_release_origins <mode> <comp...> — the guard over every tree a cut or a
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
assert_release_origins() {
    local mode="$1"; shift
    local comp src
    for comp in "$@"; do
        src="$(src_for "${comp}")"
        [ -d "${src}" ] || { echo "✗ ${comp} source worktree missing: ${src}" >&2; return 1; }
        assert_release_origin "${comp}" "${src}" "$(registry_src_for "${comp}")" "${mode}" "${CHANNEL:-stable}" || return 1
    done
    case " $* " in
        *" edge "*)
            # edge.web is always checked against ITS main, both channels — a
            # beta edge cut still bakes its covers from the stable edge.web
            # tree (spec §5.2: "Dispatcher and edge.web are always checked
            # against their main, both channels").
            [ -d "${EDGE_WEB}" ] || { echo "✗ edge.web source worktree missing: ${EDGE_WEB}" >&2; return 1; }
            assert_release_origin edge.web "${EDGE_WEB}" "${REG_EDGE_WEB}" "${mode}" stable || return 1
            ;;
    esac
    _disp_src="$(src_for dispatcher)"
    [ -d "${_disp_src}" ] || { echo "✗ dispatcher source worktree missing: ${_disp_src}" >&2; return 1; }
    assert_release_origin dispatcher "${_disp_src}" "${REG_DISPATCHER}" "${mode}" "${CHANNEL:-stable}" || return 1
    assert_release_origin "release repo" "${REPO_ROOT}" "${REG_RELEASE}" "${mode}" stable \
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
# and the release repo itself, via assert_release_origins' unconditional tail.
#
# Retention runs HERE, after the publish succeeded — never before. The
# publish (just above) is what establishes that the newest stamp is safely
# uploaded, and pruning to "newest 10" against a count that is about to
# change is exactly how a retention pass deletes something it should have
# kept.
#
# This replaces the report-then-drain contract this RUNBOOK used to
# document. That contract was sound in principle and empty in practice:
# nothing ran the drain, on either brand, for months, and the buckets
# reached 27.3 GB and 6.5 GB of unreachable artifacts. A control nobody
# executes is not a control.
if [ "${1:-}" = "publish" ]; then
    shift
    comp="${1:-}"
    [ -n "${comp}" ] || { echo "usage: release.sh publish <cli|gateway|edge|agent|all> [--version <v>]" >&2; exit 1; }
    shift || true
    assert_release_origins strict || exit 1
    build_register_helper
    "${REGISTER_BIN}" publish --comp "${comp}" "$@"
    echo
    echo "→ retention (applying):"
    # Scope, BOTH surfaces: `publish --comp all` expands to cli/gateway/edge/
    # agent (runPublish's own list) — relay is never console-promoted, it has
    # no `publish` step at all. But `prune --comp all` DOES include relay, so
    # passing "all" straight through drained relay's R2 to keep=3 on behalf of
    # a publish that had not touched a single relay object. Expand to the same
    # PUBLIC_COMPONENTS list (tools/public_components.sh), not a second copy,
    # and loop — `prune --comp` takes exactly one component.
    prune_comps="${comp}"
    [ "${comp}" = all ] && prune_comps="${PUBLIC_COMPONENTS}"
    # Channel: the literal `stable`, NOT "${CHANNEL:-stable}". register publish
    # (above) is stable-only — Publish() takes no --channel flag at all — and a
    # `:-` fallback on this name is exactly what the CHANNEL="stable" comment
    # below forbids: CHANNEL is generic enough that a stray `export
    # CHANNEL=beta` in an operator's shell would silently skip stable retention
    # here and run a keep-1 BETA sweep in its place. A bare "${CHANNEL}" is not
    # the alternative either (`set -u`, and CHANNEL is not assigned until past
    # this branch's `exit 0`) — a literal is, as at the other two sites.
    for prune_comp in ${prune_comps}; do
        "${REGISTER_BIN}" prune --comp "${prune_comp}" --channel stable --execute || true
    done
    # GitHub prune scope is cli/gateway/edge/agent (relay has no GitHub release)
    # — the same PUBLIC_COMPONENTS expansion as the R2 half above.
    # `env -u KEEP`: prune-releases.sh reads KEEP from the environment
    # (KEEP="${KEEP:-10}"), which was fine while a human typed the command and
    # is not fine now that a cut fires it automatically — an operator's leftover
    # `export KEEP=1` would silently turn this drain into a keep-1 sweep of the
    # component that was just promoted. Strip it so the script's own defaults
    # govern; this file carries no retention counts.
    env -u KEEP COMPONENTS="${prune_comps}" CHANNEL=stable \
        bash "${REPO_ROOT}/tools/prune-releases.sh" --execute || true
    exit 0
fi

# ---- args -------------------------------------------------------------------
WHAT=""
DRY_RUN=0
BUMP_KIND="patch"
FORCE_BUMP=0
# CHANNEL: stable (default) or beta — see tools/version.sh, tools/release_origin.sh
# and do_release()'s CHANNEL=beta branch below. A plain literal default, NOT
# an env fallback (unlike RELEASE_HOST/STATIC_DIR/etc.): CHANNEL is a generic
# enough name that a stray `export CHANNEL=beta` left over in an operator's
# shell — from anything, this script included — would silently turn a
# hand-run `bash tools/release.sh cli --public` into a beta cut of a repo
# whose main is a live cut origin. The ONLY way to select beta is the
# `--channel beta` flag in the arg loop below; nothing reads CHANNEL out of
# the process environment as an implicit default. tools/release.command
# always passes --channel explicitly (reading its own CHANNEL from
# .release-request), so nothing depends on an env fallback existing.
CHANNEL="stable"
# --keep-version: pin versions/<comp>, mint a fresh stamp anyway. Deliberately a
# separate variable rather than a fourth BUMP_KIND: BUMP_KIND selects WHICH bump
# runs, and this flag's whole point is that none does — folding it in would make
# `[ "${BUMP_KIND}" = patch ]` (the reuse gate below) silently true for it.
KEEP_VERSION=0

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
# --channel is a two-token flag: `--channel beta`. bash 3.2 (this script's
# target — see tools/RUNBOOK.md and every other two-token flag in this repo)
# has no `shift` inside a `for … in "$@"` loop, so the token that follows
# --channel is captured via a one-shot latch instead: expect_channel=1 tells
# the NEXT iteration "the arg you're about to see is the channel value, not a
# new flag" — the catch-all `*)` arm below is what actually consumes it.
expect_channel=0
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
        --keep-version)       KEEP_VERSION=1 ;;
        --channel)            expect_channel=1 ;;
        -h|--help)            sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)
            if [ "${expect_channel}" = 1 ]; then
                CHANNEL="${arg}"; expect_channel=0
            else
                echo "✗ unknown argument: ${arg}" >&2; exit 2
            fi
            ;;
    esac
done
[ "${expect_channel}" = 0 ] || { echo "✗ --channel needs a value: stable or beta" >&2; exit 2; }
case "${CHANNEL}" in
    stable|beta) ;;
    *) echo "✗ --channel must be stable or beta (got '${CHANNEL}')" >&2; exit 2 ;;
esac
# --distribute-only re-publishes an already-staged, already-GitHub-released
# component (`rkit build` + gh_release_publish) — a beta cut never creates a
# GitHub Release at all (it uploads straight to R2), so the two are mutually
# exclusive. See do_release()'s CHANNEL=beta branch below.
[ "${DISTRIBUTE_ONLY}" = 1 ] && [ "${CHANNEL}" = beta ] \
    && { echo "✗ --distribute-only is a stable-channel verb; a beta cut uploads to R2 in one step" >&2; exit 2; }
if [ "${DISTRIBUTE_ONLY}" = 1 ]; then
    [ -z "${WHAT}" ] || { echo "✗ --distribute-only takes <comp> <stamp> as its own args — drop the trailing '${WHAT}'" >&2; exit 2; }
else
    [ -n "${WHAT}" ] || { echo "✗ usage: release.sh <cli|gateway|edge|agent|relay|all> [--channel stable|beta] [--apple] [--vulncheck|--public] [--dry-run] [--bump-minor|--bump-major|--keep-version] [--force]" >&2; exit 2; }
fi

# --keep-version pins versions/<comp>; --bump-minor/--bump-major/--force each
# move it. Refuse the combination outright rather than letting one win: "keep
# 0.2.0" and "go to 0.3.0" publish different version numbers, and nothing in the
# cut's output would tell the operator which reading ran. Written as if/case
# (never `[ … ] && var=…`): under `set -e` a failing test at the head of an
# AND-list is the list's exit status, which aborts the script — the same trap
# the load_apple_account block further down carries a comment about.
if [ "${KEEP_VERSION}" = 1 ]; then
    KV_CONFLICT=""
    case "${BUMP_KIND}" in
        minor) KV_CONFLICT="--bump-minor" ;;
        major) KV_CONFLICT="--bump-major" ;;
    esac
    if [ "${FORCE_BUMP}" = 1 ]; then
        if [ -n "${KV_CONFLICT}" ]; then KV_CONFLICT="${KV_CONFLICT} and --force"; else KV_CONFLICT="--force"; fi
    fi
    if [ -n "${KV_CONFLICT}" ]; then
        echo "✗ --keep-version cannot be combined with ${KV_CONFLICT}: --keep-version pins versions/<comp>, ${KV_CONFLICT} would bump it." >&2
        echo "  Pick one of:" >&2
        echo "    --keep-version                republish the SAME semver over a fresh stamp (payload re-cut)" >&2
        echo "    --bump-minor | --bump-major   move the semver" >&2
        echo "    --force                       bump even when the source is unchanged" >&2
        echo "    (no flag)                     default patch bump when the source changed" >&2
        exit 2
    fi
    if [ "${DISTRIBUTE_ONLY}" = 1 ]; then
        echo "✗ --keep-version cannot be combined with --distribute-only: --distribute-only publishes an already-staged stamp and never touches versions/<comp>." >&2
        echo "  Pick one of:" >&2
        echo "    release.sh --distribute-only <cli|gateway|edge|agent> <stamp> [--dry-run]" >&2
        echo "    release.sh <cli|gateway|edge|agent|relay|all> --keep-version [--dry-run]" >&2
        exit 2
    fi
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
        # Session before account: both are "can this machine do it at all", and
        # this one is the cheaper question. A --dry-run never reaches notarize,
        # so it is exempt.
        if [ "${DRY_RUN}" != 1 ]; then
            require_desktop_session || exit 1
        fi
        load_apple_account "${REPO_ROOT}" || exit 1
    fi
fi

# ---- config / defaults ------------------------------------------------------
RELEASE_HOST="${RELEASE_HOST:-nsm.renative.com}"
STATIC_DIR="${STATIC_DIR:-/ebs_storage/apps/release.burrowee.com/static}"
RELEASE_REPO="${BURROWEE_RELEASE_REPO:-burrowee-git/release}"
DP_DIR="${DP_DIR:-${REPO_ROOT}/../../../release.dp/code/main}"
AGE_KEY_AGE="${DP_DIR}/burrowee-release.key.age"
AGE_IDENTITY="${AGE_IDENTITY:-${HOME}/.age/burrowee-release.txt}"

# REG_*/SRC_*/EDGE_WEB/registry_src_for/src_for/assert_release_origins are defined
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
# All three of source, semver and stamp file follow the CUT's channel. They used
# to be pinned to stable, which meant a beta cut bundled the dispatcher built
# from main, numbered from versions/burrowee, and RECORDED into
# versions/burrowee.stamp — a beta cut mutating stable state, and dispatcher work
# on the beta branch never reaching a beta build at all.
resolve_disp_stamp() {
    local cur_sha semver recorded rec_sha rec_sv fresh src DISP_STAMP_FILE
    src="$(src_for dispatcher)"
    DISP_STAMP_FILE="$(disp_stamp_file "${REPO_ROOT}")"
    cur_sha="$(git -C "${src}" rev-parse --short=8 HEAD)"
    semver="$(SRC_DIR="${src}" bash "${REPO_ROOT}/tools/version.sh" burrowee $(disp_channel_args) --semver | tr -d '[:space:]')"
    if [ -f "${DISP_STAMP_FILE}" ]; then
        recorded="$(tr -d '[:space:]' < "${DISP_STAMP_FILE}")"
        rec_sha="${recorded##*.}"                 # trailing sha8 segment
        rec_sv="$(printf '%s' "${recorded}" | sed -E 's/^v([0-9]+\.[0-9]+\.[0-9]+)\..*/\1/')"
        if [ "${rec_sha}" = "${cur_sha}" ] && [ "${rec_sv}" = "${semver}" ]; then
            printf '%s' "${recorded}"; return 0   # unchanged → reuse (date frozen)
        fi
    fi
    fresh="$(SRC_DIR="${src}" bash "${REPO_ROOT}/tools/version.sh" burrowee $(disp_channel_args) --stamp | tr -d '[:space:]')"
    if [ "${DRY_RUN:-0}" != 1 ]; then
        printf '%s\n' "${fresh}" > "${DISP_STAMP_FILE}"
        # Rides the [RELEASED] marker commit; if the cut aborts before that
        # commit, revert_dispatcher_version() (below, in the EXIT/INT/TERM
        # trap) restores this staged write so a never-released date isn't
        # left behind for the next unchanged-source cut to reuse.
        ( cd "${REPO_ROOT}" && git add "${DISP_STAMP_FILE#"${REPO_ROOT}"/}" )
    fi
    printf '%s' "${fresh}"
}

# assert_stamp_untagged <comp> <stamp> — refuse a cut whose tag already exists.
#
# Only --keep-version can reach this: every other path either bumps the semver
# (new tag by construction) or reuses a stamp whose tag is already published,
# which the reuse gate treats as "nothing changed" rather than a re-cut.
# --keep-version deliberately republishes a live semver, so the ONE thing that
# still has to be unique — the full stamp, semver + date + source sha — has to be
# checked, and checked HERE in step (1) where a refusal is free.
# gh_release_publish carries the identical check, but it only fires after four
# cross-compiles, a CVE scan and a notarization round-trip.
#
# Local tags only, matching gh_release_publish: a tag pushed from another machine
# and not yet fetched is invisible to both. `git fetch --tags` before a cut if the
# release repo's tag list may be behind origin.
assert_stamp_untagged() {
    local comp="$1" stamp="$2"
    local tag="${comp}/${stamp}"
    if git -C "${REPO_ROOT}" rev-parse -q --verify "refs/tags/${tag}" >/dev/null 2>&1; then
        echo "✗ ${comp}: tag ${tag} already exists — that exact stamp (semver + date + source sha) is already published." >&2
        echo "  --keep-version re-mints a stamp over the CURRENT source commit; today that lands on a tag already taken." >&2
        echo "  Either cut from a newer ${comp} commit, or drop --keep-version and let the bump run." >&2
        return 1
    fi
    return 0
}

# version_sh <comp> [args...] — tools/version.sh, with --channel "${CHANNEL}"
# threaded through every call site so a beta cut reads/writes versions/<comp>.beta
# instead of versions/<comp>, without every call site spelling out the flag.
# SRC_DIR (an env-var override on the caller's command line, e.g.
# `SRC_DIR="${src}" version_sh "${comp}" --stamp`) still reaches tools/version.sh
# exactly as it did through the old bare `bash tools/version.sh` calls: a
# variable assignment ahead of a shell function call exports it for that one
# call, function body included, same as it would for an external command.
#
# POSITIONAL CONTRACT, pinned here because nothing else records it: this only
# works because `--channel beta` lands at argv position 2 — tools/version.sh's
# own parse is `if [ "${2:-}" = "--channel" ]; then CHANNEL="${3:-}"; shift 2;
# fi`, i.e. it looks ONLY at $2, never scans for --channel anywhere in the
# arglist. A future reorder in either file (e.g. version_sh forwarding
# --channel after the action instead of before it, or version.sh's own parse
# moving to $3) breaks every call site here at once — silently: the symptom
# is a wrong-channel version FILE (version.sh falls through to reading/
# writing the stable versions/<comp> instead of refusing), not a parse error.
# tools/version.test.sh exercises this shape directly.
version_sh() {
    local comp="$1"; shift
    bash "${REPO_ROOT}/tools/version.sh" "${comp}" --channel "${CHANNEL:-stable}" "$@"
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
# --keep-version (KEEP_VERSION=1) short-circuits all of the above: versions/<comp>
# is never touched and a fresh stamp is minted over the current commit, guarded by
# assert_stamp_untagged (above) so the re-cut cannot land on a published tag.
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

    # Beta: refuse before touching anything else — a beta that does not read
    # newer than its stable sibling would ship a `version` output a beta node
    # (and the follow-on stable cut) can't trust. See tools/version.sh.
    if [ "${CHANNEL:-stable}" = beta ]; then
        version_sh "${comp}" --assert-beta-above-stable || exit 1
    fi

    cur_sha="$(git -C "${src_dir}" rev-parse --short=8 HEAD)"
    semver="$(SRC_DIR="${src_dir}" version_sh "${comp}" --semver | tr -d '[:space:]')"
    stamp_file="${REPO_ROOT}/versions/${comp}.stamp"
    [ "${CHANNEL:-stable}" = beta ] && stamp_file="${REPO_ROOT}/versions/${comp}.beta.stamp"

    if [ -f "${stamp_file}" ]; then
        recorded="$(tr -d '[:space:]' < "${stamp_file}")"
        rec_sha="${recorded##*.}"                 # trailing sha8 segment
        rec_sv="$(printf '%s' "${recorded}" | sed -E 's/^v([0-9]+\.[0-9]+\.[0-9]+)\..*/\1/')"
        if [ "${rec_sha}" = "${cur_sha}" ] && [ "${rec_sv}" = "${semver}" ]; then
            unchanged=1
        fi
    fi

    # --keep-version: versions/<comp> is left byte-identical — no bump of any
    # kind — and a fresh stamp is minted over the CURRENT commit. Deliberately
    # ahead of BOTH the dry-run branch and the unchanged-source reuse gate:
    #   * ahead of the reuse gate, because the entire point is a NEW stamp for a
    #     semver that is already published — reusing the recorded stamp would
    #     re-cut the exact release that is already live;
    #   * ahead of the dry-run branch, because the semver never moves on this
    #     path, so the stamp a dry-run prints is bit-for-bit the one a real run
    #     would mint. That makes --dry-run genuinely predictive here (it is not,
    #     on the bump paths, where dry-run reports the UNBUMPED semver) and lets
    #     the collision guard fail the operator before anything is built.
    # It writes nothing under --dry-run, so dry-run still never bumps and never
    # mints a recorded stamp.
    if [ "${KEEP_VERSION:-0}" = 1 ]; then
        fresh="$(SRC_DIR="${src_dir}" version_sh "${comp}" --stamp | tr -d '[:space:]')"
        assert_stamp_untagged "${comp}" "${fresh}" || exit 1
        echo "→ ${comp}: --keep-version — REPUBLISHING semver ${semver}; versions/${comp}$([ "${CHANNEL:-stable}" = beta ] && printf '.beta') not bumped, fresh stamp ${fresh}" >&2
        if [ "${DRY_RUN:-0}" != 1 ]; then
            # Same record-and-stage as the bump path below, minus the bump. The
            # caller's revert_version/revert_relay_version trap restores this
            # staged write if the cut dies; versions/<comp>[.beta] itself is
            # never written here, so the trap's restore of it is a no-op.
            printf '%s\n' "${fresh}" > "${stamp_file}"
            ( cd "${REPO_ROOT}" && git add "${stamp_file#"${REPO_ROOT}"/}" )
        fi
        printf '%s' "${fresh}"
        return 0
    fi

    if [ "${DRY_RUN:-0}" = 1 ]; then
        if [ "${unchanged}" = 1 ]; then
            printf '%s' "${recorded}"
        else
            SRC_DIR="${src_dir}" version_sh "${comp}" --stamp | tr -d '[:space:]'
        fi
        return 0
    fi

    if [ "${unchanged}" = 1 ] && [ "${BUMP_KIND}" = patch ] && [ "${FORCE_BUMP:-0}" != 1 ]; then
        printf '%s' "${recorded}"; return 0   # unchanged, default bump → reuse (no bump)
    fi

    case "${BUMP_KIND}" in
        patch) SRC_DIR="${src_dir}" version_sh "${comp}" --bump-patch >/dev/null ;;
        minor) SRC_DIR="${src_dir}" version_sh "${comp}" --bump-minor >/dev/null ;;
        major) SRC_DIR="${src_dir}" version_sh "${comp}" --bump-major >/dev/null ;;
    esac
    fresh="$(SRC_DIR="${src_dir}" version_sh "${comp}" --stamp | tr -d '[:space:]')"
    printf '%s\n' "${fresh}" > "${stamp_file}"
    # Rides the [RELEASED] marker commit; if the cut aborts before that
    # commit, the caller's revert_version/revert_relay_version trap restores
    # this staged write so a never-released date isn't left behind for the
    # next unchanged-source cut to wrongly reuse.
    ( cd "${REPO_ROOT}" && git add "${stamp_file#"${REPO_ROOT}"/}" )
    printf '%s' "${fresh}"
}

# edge skills source-of-truth (the edge repo owns these)
EDGE_SKILLS_SRC="${SRC_EDGE}/skills"

# assert_platform_coverage <comp> <stage_dir> — fails loudly, naming the
# component and the missing platform(s), when <stage_dir> does not carry
# every burrowee-<comp>-<plat>.zip TARGETS expects.
#
# Why this exists: register_staged's own loop (below) treats a missing zip as
# "omit that one artifact and keep going" — deliberately, for the case where
# an externally-staged dir (rkit build) predates this script's TARGETS
# growing a platform rkit was never taught. That tolerance means a short
# stage still registers, still exits 0, and still publishes a release that
# LOOKS complete. Today that is exactly darwin-amd64-legacy: rkit builds only
# the original four targets (internal/relconfig.Targets() has no fifth-target
# or overlay concept — see tools/RUNBOOK.md), so `rkit build` ->
# `release.sh --distribute-only` silently ships four platforms forever unless
# something here refuses.
#
# Runs ahead of the DRY_RUN branch in distribute_only() (same placement as
# assert_payload_migrations) so a --dry-run rehearsal catches a short stage
# too, not just a real cut.
#
# Public components only (cli/gateway/edge/agent) — distribute_relay()
# derives its platform set from the STAGED zips on purpose (see its own
# comment) because relay's separately-versioned rkit build is already known
# to lag TARGETS; that is an intentional, already-documented tolerance and is
# out of scope for this assertion.
#
# RELEASE_SH_EXPECT_MISSING names the EXACT platform(s) expected absent — a
# space- or comma-separated list, e.g. "darwin-amd64-legacy" — checked
# against the ACTUAL computed missing set, not a count. A bare count (the
# first cut of this gate) could not tell "the expected platform is missing"
# from "some other platform is missing but the total happens to match", which
# is the one failure mode this assertion exists to catch — so the comparison
# must be exact, in both directions:
#   - a missing platform NOT in the declared set fails, naming it (same as
#     an unset/empty declaration always has);
#   - a platform IN the declared set that is NOT actually missing also fails
#     — a stale declaration must not linger silently once the real gap
#     closes; requiring an exact match is what makes the override
#     self-expiring rather than set-and-forget.
# Component-scoped: RELEASE_SH_EXPECT_MISSING_<COMP> (uppercased comp, e.g.
# RELEASE_SH_EXPECT_MISSING_CLI) takes precedence over the bare
# RELEASE_SH_EXPECT_MISSING when both are set, so one component's declared
# gap can't accidentally cover another's stage. Set it ONLY to declare a
# deliberately-short stage is expected (test fixtures; an operator who has
# already read the rkit-gap note in RUNBOOK.md and is knowingly distributing
# a partial stage). A real distribute-only cut must never set it.
assert_platform_coverage() {
    local comp="$1" stage_dir="$2"
    local -a missing=()
    local triple os arch variant plat zip_name
    for triple in "${TARGETS[@]}"; do
        # shellcheck disable=SC2086  # triple is a controlled space-separated string; word-splitting gives os arch [variant].
        read -r os arch variant <<<"${triple}"
        plat="$(plat_of "${os}" "${arch}" "${variant}")"
        zip_name="burrowee-${comp}-${plat}.zip"
        [ -f "${stage_dir}/${zip_name}" ] || missing+=("${plat}")
    done

    # Resolve the declared-missing set: component-scoped override wins over
    # the bare one; comma or space separated, either works.
    local comp_upper var_name declared
    comp_upper="$(printf '%s' "${comp}" | tr '[:lower:]' '[:upper:]')"
    var_name="RELEASE_SH_EXPECT_MISSING_${comp_upper}"
    declared="${!var_name:-${RELEASE_SH_EXPECT_MISSING:-}}"
    declared="${declared//,/ }"

    # contains_word <space-list> <word> — exact-token membership, not substring.
    contains_word() {
        local list=" $1 " word="$2"
        case "${list}" in *" ${word} "*) return 0 ;; *) return 1 ;; esac
    }

    local -a undeclared=() stale=()
    local m d
    # bash 3.2's `set -u` treats `"${arr[@]}"` on a zero-length array as an
    # unbound-variable error, not an empty expansion — guard the count before
    # iterating (the common case: nothing missing, missing[] is empty).
    if [ "${#missing[@]}" -gt 0 ]; then
        for m in "${missing[@]}"; do
            contains_word "${declared}" "${m}" || undeclared+=("${m}")
        done
    fi
    for d in ${declared}; do
        contains_word "${missing[*]:-}" "${d}" || stale+=("${d}")
    done

    if [ "${#undeclared[@]}" -gt 0 ] || [ "${#stale[@]}" -gt 0 ]; then
        echo "✗ ${comp}: staged platform set does not match the declared expectation" >&2
        [ "${#undeclared[@]}" -gt 0 ] && echo "  missing but not declared: ${undeclared[*]}" >&2
        [ "${#stale[@]}" -gt 0 ] && echo "  declared missing but actually staged: ${stale[*]}" >&2
        echo "  stage dir: ${stage_dir}" >&2
        echo "  set RELEASE_SH_EXPECT_MISSING (or RELEASE_SH_EXPECT_MISSING_${comp_upper}) to the EXACT platform(s) expected missing — space- or comma-separated (see tools/RUNBOOK.md — rkit gap)" >&2
        exit 1
    fi
}

# src_for is defined earlier in this file, beside REG_*/SRC_*/assert_release_origins.

# binary list per component (the dispatcher `burrowee` is added at assembly time)
# bins_for <comp> — which binaries this component's ZIP CARRIES — is defined in
# tools/binmap.sh (sourced above), derived from the same table tools/build.sh
# reads for what gets BUILT. It used to be an independent `case` here, i.e. a
# second copy of a fact whose third copy (internal/relconfig.Bins) claimed by
# comment to mirror the first. A binary present in the build list and absent
# here is built, Developer-ID signed, notarized and silently NOT packaged; only
# the reverse fails closed, on the assembly `cp` below.

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
#
# HOW A FAILED CONSOLE POST IS REPORTED: REG_STAGED_FAILED, never the return
# status. A correctness requirement, not a style choice.
#
# (Deliberately not spelled with a `# ----` rule: that prefix is the section
# sentinel tools/test-register-staged.sh's extract_register_staged stops at,
# so a rule inside this header truncates the extraction and every test in
# that file dies with "register_staged: command not found".)
#
# This function ALWAYS returns 0, and every call site calls it UNGUARDED —
# no `|| rc=$?`, no `|| true`, no `if register_staged ...; then`.
#
# Bash disables `errexit` for the whole left-hand side of an AND-OR list, and
# that suppression reaches INSIDE the called function's body — not merely its
# exit status. So `register_staged ... || rc=$?` silently turns off `set -e`
# for everything this function does:
#
#   inner(){ exit 1; }; f(){ local v=""; v="$(inner)"; echo "v='$v'"; return 0; }
#   f            -> script aborts (rc=1)
#   f || rc=$?   -> "v=''"  rc=0      <- errexit suppressed inside f
#
# That matters because several assignments in here are deliberately
# FAIL-CLOSED, and a command substitution's failure only kills its subshell —
# `errexit` in the parent is what turns it into an aborted cut:
#
#   updater_ver="$(updater_pin ...)"   exits 1 on a pseudo-version, a missing
#                                      .info, a missing Time/Origin.Hash, or a
#                                      bare `go list -m` failure. Swallowed, it
#                                      yields "" and POSTs "updater_version":""
#                                      to the console catalog and the fleet —
#                                      exactly what updater_pin's own header and
#                                      tools/test-register-staged.sh TEST 8 exist
#                                      to prevent.
#   key_prefix="$(... key-prefix ...)" swallowed, it yields "" and every beta /
#                                      relay key loses its "<comp>/" prefix.
#   json_escape's `jq`, size="$(wc -c ...)" — same class.
#
# `if register_staged ...; then` is NOT an alternative: it suppresses errexit
# identically.
#
# So the POST outcome travels through a variable instead. REG_STAGED_FAILED is
# reset to 0 on entry and set to 1 only when the register helper's POST fails
# (loud warn either way). Callers read it immediately after an unguarded call:
#
#   register_staged ...                      # errexit stays live
#   if [ "${REG_STAGED_FAILED}" = 0 ]; then <drain>; else <skip>; fi
#
# Post-failure stays NON-FATAL — a failed POST must never fail a release whose
# artifacts are already up. What the flag is for is the retention drains: a
# drain must not run when no console row was created. See the
# REG_STAGED_FAILED=1 comment at the bottom of this function.
#
# The two SKIP branches below (~/.burrowee/release unconfigured, and no
# artifact zips found under stage_dir) leave REG_STAGED_FAILED at 0. They are
# the same "no row exists" state, and they are left alone deliberately: both
# are unreachable on the gated paths where the drain is dangerous — a beta or
# relay cut reaches this function only past its own `register publish-dir` /
# `publish-relay`, which reads config.toml from the SAME path this skip
# tests, under `set -e`; and both build every TARGETS zip themselves before
# calling here, so a zero-zip stage_dir cannot exist by then. They stay
# reachable from --distribute-only over an externally staged dir, where the
# drain is stable-only (keep 3/10, not 1) and the previous version survives.
#
# For public comps: url_or_key is the GitHub asset download URL.
# For relay: url_or_key is the R2 key under relay/<stamp>/.
# gated=true iff comp==relay. github_release=<comp>/<stamp> for public, ""
# for relay. prerelease=true always.
warn() { echo "⚠ $*" >&2; }

# Set by register_staged (see its header): 0 = a console row was created, or
# the call was a dry run; 1 = the POST was attempted and failed. Declared at
# script scope so `set -u` cannot bite a reader that runs before any call.
REG_STAGED_FAILED=0
register_staged() {
    # NOT `local` — this is how the outcome reaches the caller, because the
    # return status cannot be read without disabling errexit inside this body.
    REG_STAGED_FAILED=0
    local comp="$1" stamp="$2" semver="$3" stage_dir="$4" src_dir="$5"
    local gh_tag="${6:-}"
    # Read from the caller's environment, defaulting stable — the callers this
    # runs under (do_release, do_release_relay, distribute_only, distribute_relay)
    # all have CHANNEL set by the time they reach here; the default only matters
    # for tools/test-register-staged.sh's isolated function-extraction harness.
    local channel="${CHANNEL:-stable}"

    local gated=false
    local github_release="${gh_tag}"
    [ "${comp}" = relay ] && gated=true && github_release=""
    # A beta row is never a GitHub Release (spec §5.3) — forced empty
    # regardless of comp, in ADDITION to relay's own always-empty rule above.
    [ "${channel}" = beta ] && github_release=""

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

    # sha256_bundle: sha256 of SHA256SUMS.txt (covers all five platform zips).
    local sha256_bundle
    # shellcheck disable=SC2086
    sha256_bundle="$(${SHA256} "${stage_dir}/SHA256SUMS.txt" 2>/dev/null | awk '{print $1}')" || sha256_bundle=""

    # Ask the register binary for the layout rather than rebuilding it here —
    # internal/register/KeyPrefix is the single expression of it, and a shell
    # copy is a copy that drifts.
    local key_prefix
    key_prefix="$("${REGISTER_BIN}" key-prefix --comp "${comp}" --channel "${channel}")"

    # Build artifacts JSON.
    # For each platform zip, extract sha256 + size, derive url_or_key.
    # Public comps: zips are named burrowee-<comp>-<plat>.zip in stage_dir.
    # Relay: zips are named latest.<plat>.zip in stage_dir (the latest_stage).
    # Iterates the SAME TARGETS triples every other assembly/publish site uses,
    # so darwin-amd64-legacy's artifacts key/zip names cannot drift from theirs.
    local artifacts_json="{" first=1 any_found=0
    for triple in "${TARGETS[@]}"; do
        local os arch variant
        # shellcheck disable=SC2086  # triple is a controlled space-separated string; word-splitting gives os arch [variant].
        read -r os arch variant <<<"${triple}"
        local plat; plat="$(plat_of "${os}" "${arch}" "${variant}")"

        local zip_name url_or_key zip_path
        if [ "${comp}" = relay ]; then
            # ${key_prefix}, not a hardcoded "relay/": relay has a beta channel
            # too (do_release_relay --channel beta), and its bytes land under
            # relay/beta/<stamp>/ exactly like every other component's. A
            # hardcoded prefix here made a relay beta row point at keys the
            # publish never wrote.
            zip_name="latest.${plat}.zip"
            url_or_key="${key_prefix}${stamp}/${zip_name}"
        elif [ "${channel}" = beta ]; then
            # Beta: same R2 key layout as relay's private publish
            # (register publish-dir → internal/r2), just under the
            # component's own prefix instead of relay/ — no GitHub asset to
            # link, since a beta cut never creates a Release.
            zip_name="burrowee-${comp}-${plat}.zip"
            url_or_key="${key_prefix}${stamp}/${zip_name}"
        else
            zip_name="burrowee-${comp}-${plat}.zip"
            url_or_key="https://github.com/${RELEASE_REPO}/releases/download/${gh_tag}/${zip_name}"
        fi
        zip_path="${stage_dir}/${zip_name}"

        if [ ! -f "${zip_path}" ]; then
            # A platform release.sh's TARGETS knows about but this stage_dir
            # does not carry — e.g. distribute_relay()/distribute_only() over
            # a dir `rkit build` staged before rkit was taught a
            # newly-added platform. Omit just this one artifact entry rather
            # than abandoning registration for every platform that DID stage
            # (the old behavior: one absent zip silently skipped the whole
            # console row, public comps included).
            #
            # Deferred note: this `continue` (and the any_found guard below)
            # is unreachable from the full-cut path — do_release()/
            # do_release_relay() build every TARGETS platform themselves,
            # under `set -e`, before ever calling register_staged, so a
            # missing zip there already aborted the cut earlier. It exists
            # for the externally-staged case: distribute_only()/
            # distribute_relay() calling register_staged over a dir this
            # script did not assemble (rkit build produced it). That gap is
            # now caught earlier and louder, for public comps, by
            # assert_platform_coverage() in distribute_only() above — this
            # loop's per-artifact tolerance is what runs after that gate has
            # already passed (or been explicitly overridden).
            echo "⚠ console registration: zip not found: ${zip_path} — omitting from artifacts" >&2
            continue
        fi
        any_found=1

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
    if [ "${any_found}" != 1 ]; then
        echo "⚠ console registration: no artifact zips found for ${comp} under ${stage_dir} — skipping" >&2
        return 0
    fi
    artifacts_json="${artifacts_json}}"

    # sums_ref and minisig_ref: public = GitHub asset URLs; relay/beta = R2 keys.
    local sums_ref minisig_ref
    if [ "${comp}" = relay ]; then
        # ${key_prefix} for the same reason as the artifacts loop above — a
        # relay beta cut's sums/minisig live under relay/beta/<stamp>/.
        sums_ref="${key_prefix}${stamp}/SHA256SUMS.txt"
        minisig_ref="${key_prefix}${stamp}/SHA256SUMS.txt.minisig"
    elif [ "${channel}" = beta ]; then
        sums_ref="${key_prefix}${stamp}/SHA256SUMS.txt"
        minisig_ref="${key_prefix}${stamp}/SHA256SUMS.txt.minisig"
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
    body="{\"component\":\"$(json_escape "${comp}")\",\"version\":\"$(json_escape "${stamp}")\",\"semver\":\"$(json_escape "${semver}")\",\"channel\":\"$(json_escape "${channel}")\",\"gated\":${gated},\"artifacts\":\"$(json_escape "${artifacts_json}")\",\"sums_ref\":\"$(json_escape "${sums_ref}")\",\"minisig_ref\":\"$(json_escape "${minisig_ref}")\",\"github_release\":\"$(json_escape "${github_release}")\",\"prerelease\":true,\"source_sha\":\"$(json_escape "${source_sha}")\",\"sha256\":\"$(json_escape "${sha256_bundle}")\",\"notes\":\"\",\"binaries\":${binaries_json},\"dispatcher_version\":\"$(json_escape "${DISP_STAMP}")\",\"updater_version\":\"$(json_escape "${updater_ver}")\"}"

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
        # The flag, and the warn stays. For a GATED artifact — relay on either
        # channel, and any component's beta — the console ROW, not the R2
        # object, is what makes the bytes reachable: without it the cut has
        # published something nothing can install. The retention drains that
        # follow this call gate on this flag for that reason. A beta drain is
        # keep=1, so ungated it would delete the PREVIOUS beta while the new
        # one has no row — leaving the component with no installable beta at
        # all and, per keepFor's own doc, no artifact-level rollback.
        #
        # A flag rather than `return 1` because reading a return status costs
        # `errexit` inside this whole function body — see the function header.
        # This still does not make a failed POST fatal: the function returns 0,
        # so a release whose artifacts are already up finishes exactly as
        # before; only the drain is skipped.
        REG_STAGED_FAILED=1
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
  f=<file>                                      # the file you downloaded
  want=\$(awk -v f="\$f" '{ n = \$2; sub(/^\\*/, "", n); if (n == f) { print \$1; exit } }' SHA256SUMS.txt)
  got=\$(shasum -a 256 "\$f" | awk '{print \$1}')  # sha256sum "\$f" on Linux
  if   [ -z "\$want" ];        then echo "NO ENTRY for \$f in SHA256SUMS.txt — do not install"
  elif [ "\$want" = "\$got" ];  then echo "OK \$f"
  else                             echo "MISMATCH for \$f — do not install"; fi
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

    # (1) re-stage rkit's burrowee-relay-<plat>.zip under latest.* names.
    #
    # Derived from the STAGED zips (a glob), not TARGETS: TARGETS is the full
    # cut's own target list (do_release_relay, below) and is free to grow —
    # e.g. darwin-amd64-legacy — ahead of whatever platform set the separately
    # versioned `rkit build --component relay` binary currently produces.
    # distribute_relay must re-stage whatever rkit actually built, never
    # demand a zip nothing produced.
    local latest_stage="${stage}/.latest"
    rm -rf "${latest_stage}"; mkdir -p "${latest_stage}"
    local z plat found=0
    for z in "${stage}/burrowee-${comp}-"*.zip; do
        [ -f "${z}" ] || continue
        found=1
        plat="$(basename "${z}")"
        plat="${plat#burrowee-"${comp}"-}"
        plat="${plat%.zip}"
        # The same relay payload gate the full cut runs, applied to zips this
        # path did NOT assemble (rkit build produced them) — mirrors
        # distribute_only's loop for the public components. Whichever assembler
        # ran, a relay kit without its migration ladder must not reach R2 or
        # the console catalog; ahead of the dry-run branch so a rehearsal fails
        # on it too.
        assert_payload_migrations "${comp}" "${z}" "${src}" || exit 1
        cp "${z}" "${latest_stage}/latest.${plat}.zip"
    done
    [ "${found}" = 1 ] \
        || { echo "✗ no burrowee-${comp}-*.zip staged under ${stage} (run rkit build --component relay first)" >&2; exit 1; }
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
    local tcomment; tcomment="$(trusted_comment "${comp}" "${stamp}")"
    ( cd "${latest_stage}" && minisign -S -s "${sign_key}" -m SHA256SUMS.txt \
        -t "${tcomment}" >/dev/null )
    shred_key

    echo "Relay latest.* set + SHA256SUMS.txt + .minisig staged under ${latest_stage}:"
    # shellcheck disable=SC2012
    ( cd "${latest_stage}" && ls -1 latest.*.zip SHA256SUMS.txt SHA256SUMS.txt.minisig | sed 's/^/    /' )

    if [ "${DRY_RUN}" = 1 ]; then
        echo "→ would: publish-relay to R2 under relay/${stamp}/"
        # Same stage-derived platform set as (1) above, not TARGETS.
        for z in "${latest_stage}/latest."*.zip; do
            [ -f "${z}" ] || continue
            echo "    relay/${stamp}/$(basename "${z}")"
        done
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
    # --channel stable spelled out, same reasoning as the prune call just
    # below: --distribute-only refuses --channel beta at arg-parse, so stable
    # is the only value this path can have — say it rather than lean on the
    # verb's default, so the call names what is actually true here.
    "${REGISTER_BIN}" publish-relay --channel stable --stamp "${stamp}" --from-dir "${latest_stage}"
    # (4) marker commit (private — no gh release / no git tag).
    git add "versions/${comp}"
    marker_commit "${REPO_ROOT}" "[RELEASED: ${comp}] $(date -u +%Y-%m-%d) ${stamp} (private)"
    # (5) console catalog row (LAST) — relay uses R2 keys, not GitHub URLs.
    # register_staged records the dispatcher stamp bundled into the zip; resolve
    # it here (the public distribute_only sets DISP_STAMP the same way).
    DISP_STAMP="$(resolve_disp_stamp)"
    # Unguarded, and the outcome read from REG_STAGED_FAILED: `|| rc=$?` here
    # would disable errexit inside register_staged's whole body, where several
    # assignments (updater_pin, key-prefix, jq) are deliberately fail-closed.
    # See register_staged's header.
    register_staged "${comp}" "${stamp}" "${semver}" "${latest_stage}" "${src}"

    # (6) Retention runs HERE, LAST — after the R2 upload, the marker commit
    # and the console registration above have all succeeded, never before, and
    # never on the dry-run path (this line is only reachable past the
    # `return 0` in the DRY_RUN branch above, which prints "would:
    # publish-relay" and returns before any upload). It used to sit directly
    # after the upload, ahead of registration: relay is GATED on every
    # channel, so the console ROW — not the R2 object — is what makes these
    # bytes installable, and draining before that row exists is draining on
    # the strength of a publish that may not have completed in the sense that
    # matters. Hence the gate on ${REG_STAGED_FAILED}, not just the reordering.
    #
    # --distribute-only refuses --channel beta (see the DISTRIBUTE_ONLY/CHANNEL
    # guard near the top of this file), so this path is provably always stable
    # — passed explicitly rather than left to prune's own default, so the call
    # names what is actually true here. `|| true`: a retention failure must not
    # fail a distribution whose artifacts are already up; the nightly
    # com.jc.r2-cleanup agent is the net for whatever a failure here leaves
    # behind, and for the skipped-drain case just below.
    if [ "${REG_STAGED_FAILED}" = 0 ]; then
        echo "→ relay R2 retention (applying):"
        "${REGISTER_BIN}" prune --comp relay --channel stable --execute || true
    else
        echo "⚠ relay R2 retention SKIPPED: console registration did not succeed" >&2
        echo "  The artifacts are up but not yet reachable. Register manually, then run:" >&2
        echo "    ${REGISTER_BIN} prune --comp relay --channel stable --execute" >&2
    fi
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

    local src semver z
    src="$(src_for "${comp}")"                    # reuse SRC_<comp> resolution
    [ -d "${src}" ] || { echo "✗ ${comp} source worktree missing: ${src}" >&2; exit 1; }
    semver="$(SRC_DIR="${src}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --semver)"

    # The same gateway payload gate the full cut runs, applied to zips this path
    # did NOT assemble (rkit build produced them). Whichever assembler ran, a
    # gateway release without its migration ladder must not reach a tag, a
    # GitHub Release or the static host. Runs ahead of the dry-run branch so a
    # rehearsal fails on it too.
    for z in "${stage}"/burrowee-"${comp}"-*.zip; do
        [ -f "${z}" ] || continue
        assert_payload_migrations "${comp}" "${z}" "${src}" || exit 1
    done

    # Fails loudly, naming the missing platform(s), if <stage> carries fewer
    # platforms than TARGETS expects — e.g. an rkit-produced stage that
    # predates rkit learning darwin-amd64-legacy. See assert_platform_coverage
    # above. Also ahead of the dry-run branch, same reasoning as the
    # migrations gate just above: a rehearsal must catch a short stage too.
    assert_platform_coverage "${comp}" "${stage}"

    if [ "${DRY_RUN}" = 1 ]; then
        echo "→ would: gh release create ${comp}/${stamp} (GitHub Release, public) via ghp"
        echo "→ would: gen-bootstraps.sh (regenerate ${comp}/install.sh + ${comp}/upgrade.sh + ${comp}/preflight.sh, and for edge/gateway ${comp}/updater.install.sh)"
        echo "→ would: scp install.sh/upgrade.sh/preflight.sh/burrowee-release.pub/site/index.html/skills (and for edge/gateway updater.install.sh) to ${RELEASE_HOST}:${STATIC_DIR}/${comp}/ (self-hosting upload)"
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

    [ -d "$(src_for dispatcher)" ] || { echo "✗ dispatcher source worktree missing: $(src_for dispatcher)" >&2; exit 1; }
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
    # Stage every PUBLIC_COMPONENTS dir's beta.*.sh sweep outcome, not only
    # ${comp}'s — same wedge and same fix as do_release()'s stable tail (see
    # the comment there): gen-bootstraps.sh sweeps EVERY public component's
    # beta.*.sh on every invocation, not only the one being distributed here.
    # A stale narrower stage left another, already-closed component's sweep
    # deletions unstaged, and release.command's tree_state() refused to push
    # the marker commit this function is about to make — AFTER gh_release_publish
    # (above) had already put the GitHub Release out. `-A -- "<dir>"` per
    # component stages whole directories, never the `"${comp}/<artifact>"`
    # shape cmd/rkit's TestReleasePublishesEveryRenderedArtifact's gitAddSites
    # needle matches, and ships nothing (no scp) — not a third publish site.
    for pubcomp in ${PUBLIC_COMPONENTS}; do
        git add -A -- "${pubcomp}"
    done
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
    # upgrade.sh is install.sh's second mode, rendered from the same template by
    # gen-bootstraps.sh: same pubkey, same preflight pin, same version floor, plus
    # the forced migration pass. It is served from the same directory and MUST be
    # uploaded beside install.sh — a rendered artifact nobody publishes is a 404
    # at a URL we advertise, which is this month's repeated defect in another
    # shape. cmd/rkit's TestReleasePublishesEveryRenderedArtifact pins all four
    # sites (scp + git add, here and in the distribute-only path).
    scp -q "${REPO_ROOT}/${comp}/upgrade.sh" "${RELEASE_HOST}:${STATIC_DIR}/${comp}/upgrade.sh"
    # preflight.sh is a sibling static file the installer fetches before the trust
    # gate (sha256-pinned in install.sh). Ship it alongside install.sh.
    if [ -f "${REPO_ROOT}/${comp}/preflight.sh" ]; then
        scp -q "${REPO_ROOT}/${comp}/preflight.sh" "${RELEASE_HOST}:${STATIC_DIR}/${comp}/preflight.sh"
    fi
    # updater.install.sh is the THIRD @MODE@ of the same template — install.sh's
    # inner script swapped for the narrow updater-recovery script. Rendered by
    # gen-bootstraps.sh for edge/gateway ONLY (see UPDATER_INSTALL_COMPONENTS
    # there), so guarded here the same way preflight.sh is guarded above, not
    # unconditional like install.sh/upgrade.sh which every public component has.
    if [ -f "${REPO_ROOT}/${comp}/updater.install.sh" ]; then
        scp -q "${REPO_ROOT}/${comp}/updater.install.sh" "${RELEASE_HOST}:${STATIC_DIR}/${comp}/updater.install.sh"
    fi
    # beta.install.sh / beta.upgrade.sh / beta.updater.install.sh: distribute-only
    # is always a STABLE republish (--distribute-only refuses --channel beta), but
    # gen-bootstraps.sh regenerates the beta twins on EVERY invocation whenever a
    # beta cycle is open — idempotent, so re-shipping them here keeps a live beta
    # cycle's bootstrap in step with THIS repo's current pubkey/preflight even
    # when only a stable component is being distributed. Guarded exactly like
    # updater.install.sh above (not every component/cycle combination has them).
    # This is the second of the two sites cmd/rkit's
    # TestReleasePublishesEveryRenderedArtifact requires per rendered artifact —
    # the first is do_release()'s CHANNEL=beta branch.
    if [ -f "${REPO_ROOT}/${comp}/beta.install.sh" ]; then
        scp -q "${REPO_ROOT}/${comp}/beta.install.sh" "${RELEASE_HOST}:${STATIC_DIR}/${comp}/beta.install.sh"
    fi
    if [ -f "${REPO_ROOT}/${comp}/beta.upgrade.sh" ]; then
        scp -q "${REPO_ROOT}/${comp}/beta.upgrade.sh" "${RELEASE_HOST}:${STATIC_DIR}/${comp}/beta.upgrade.sh"
    fi
    if [ -f "${REPO_ROOT}/${comp}/beta.updater.install.sh" ]; then
        scp -q "${REPO_ROOT}/${comp}/beta.updater.install.sh" "${RELEASE_HOST}:${STATIC_DIR}/${comp}/beta.updater.install.sh"
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
    git add "versions/${comp}" "${comp}/install.sh" "${comp}/upgrade.sh" "${comp}/preflight.sh"
    # updater.install.sh: same edge/gateway-only guard as its scp above — a
    # `git add` of a path that does not exist for this comp would abort the
    # cut under `set -e`.
    if [ -f "${REPO_ROOT}/${comp}/updater.install.sh" ]; then
        git add "${comp}/updater.install.sh"
    fi
    # Both files, not just install.sh — see the identical guard + comment in
    # do_release()'s CHANNEL=beta branch above.
    if [ -f "${REPO_ROOT}/${comp}/beta.install.sh" ] && [ -f "${REPO_ROOT}/${comp}/beta.upgrade.sh" ]; then
        git add "${comp}/beta.install.sh" "${comp}/beta.upgrade.sh"
    fi
    if [ -f "${REPO_ROOT}/${comp}/beta.updater.install.sh" ]; then
        git add "${comp}/beta.updater.install.sh"
    fi
    [ -d "${REPO_ROOT}/skills" ] && git add skills 2>/dev/null || true
    marker_commit "${REPO_ROOT}" "[RELEASED: ${comp}] $(date -u +%Y-%m-%d) ${stamp}"

    # (4) register staged row in the console catalog — LAST, only after the
    # GitHub Release + self-hosting upload + marker commit all succeeded, so
    # the catalog never advertises artifacts that aren't actually live.
    # Unguarded — see register_staged's header on why the outcome travels
    # through REG_STAGED_FAILED and not the return status.
    register_staged "${comp}" "${stamp}" "${semver}" "${stage}" "${src}" "${comp}/${stamp}"

    # Retention runs HERE, after the GitHub Release + self-hosting upload +
    # marker commit + catalog registration above have all succeeded — never
    # before, and never on the dry-run path (this line is only reachable
    # past the `return 0` in the DRY_RUN branch above, which returns before
    # gh_release_publish ever runs). "have all succeeded" is now a fact the
    # code checks rather than a sentence: register_staged used to warn and
    # return 0 on a failed console POST, so this drain ran regardless of it.
    # --distribute-only refuses --channel beta (see the DISTRIBUTE_ONLY/CHANNEL
    # guard near the top of this file), so this path is provably always stable
    # — passed explicitly rather than left to the tool's own default.
    # `|| true`: a retention failure must not fail a distribution whose
    # artifacts are already public; the nightly com.jc.r2-cleanup agent is the
    # net for whatever a failure here leaves behind, and for the skipped-drain
    # case below. No R2 side here — distribute_only never uploads to R2 for a
    # public component; that only happens later, via the stable
    # console-promote helper (the `publish` branch near the top of this file),
    # which drains R2 retention itself.
    echo
    if [ "${REG_STAGED_FAILED}" = 0 ]; then
        echo "→ GitHub release retention (applying):"
        # `env -u KEEP`: prune-releases.sh takes KEEP from the environment, and
        # this call is automatic now — a leftover `export KEEP=1` in the
        # operator's shell must not steer a destructive drain the cut fires on
        # its own. Same strip at every automatic --execute site; no retention
        # count is written here.
        env -u KEEP CHANNEL=stable COMPONENTS="${comp}" bash "${REPO_ROOT}/tools/prune-releases.sh" --execute || true
    else
        echo "⚠ GitHub release retention SKIPPED: console registration did not succeed" >&2
        echo "  Register manually, then run:" >&2
        echo "    CHANNEL=stable COMPONENTS=${comp} bash tools/prune-releases.sh --execute" >&2
    fi

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
# (tools/release_origin.sh): the registry main folder, primary worktree, on main,
# clean, and equal to origin/main — for every tree read or written. --dry-run
# reports instead of failing. Computed once here so both entry points below
# (distribute-only and the full cut) share the same mode.
RELEASE_ORIGIN_MODE=strict
[ "${DRY_RUN}" = 1 ] && RELEASE_ORIGIN_MODE=report

if [ "${DISTRIBUTE_ONLY}" = 1 ]; then
    # rkit build staged the bump; both files ride the [RELEASED] marker commit
    # distribute_only makes (`do_release`'s marker commit: `git commit` takes no pathspec
    # commits the whole index). Without this the two-step path deadlocks: staged
    # counts as dirty, and committing makes the repo ahead of origin/main.
    # mapfile/readarray is a bash-4+ builtin, not present in macOS's system
    # bash 3.2 that this script runs under (see tools/release_origin.test.sh's own
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
        assert_release_origins "${RELEASE_ORIGIN_MODE}" relay || exit 1
    elif [ "${DIST_COMP}" = edge ]; then
        assert_release_origins "${RELEASE_ORIGIN_MODE}" edge || exit 1
    else
        assert_release_origins "${RELEASE_ORIGIN_MODE}" "${DIST_COMP}" edge || exit 1
    fi
    distribute_only "${DIST_COMP}" "${DIST_STAMP}"
    exit 0
fi

# components to cut — PUBLIC_COMPONENTS (tools/public_components.sh), not a
# second hardcoded copy.
if [ "${WHAT}" = all ]; then read -r -a COMPONENTS <<< "${PUBLIC_COMPONENTS}"; else COMPONENTS=("${WHAT}"); fi

# Every do_release() (i.e. every non-relay component) mirrors the edge skills
# (EDGE_SKILLS_SRC=${SRC_EDGE}/skills) unconditionally, so the edge tree is
# read even when it is not the component being cut. Asserted here rather than
# inside do_release so a stale edge tree fails the cut before anything is
# built, and only once when edge IS already in COMPONENTS. do_release_relay
# never reads edge, so a relay-only cut (the only way COMPONENTS can be just
# "relay" — WHAT is a single token) does not assert it needlessly. Surfaced
# ahead of the DP_DIR/signing-key/ghp/ssh pre-flight below so a bad source
# tree is reported first, not masked by an unrelated environment error.
RELEASE_ORIGIN_COMPS=("${COMPONENTS[@]}")
needs_edge=0
for c in "${COMPONENTS[@]}"; do
    [ "${c}" = relay ] || { needs_edge=1; break; }
done
if [ "${needs_edge}" = 1 ]; then
    case " ${COMPONENTS[*]} " in
        *" edge "*) ;;
        *) RELEASE_ORIGIN_COMPS+=(edge) ;;
    esac
fi
assert_release_origins "${RELEASE_ORIGIN_MODE}" "${RELEASE_ORIGIN_COMPS[@]}" || exit 1

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

# Outer-bootstrap trust-chain gate (every cut, including --dry-run): the modules
# are locked, their dependencies ordered, and the committed bootstraps are what
# the generator writes. Runs before the first build for the same reason
# vulncheck_gate does — a tree whose install chain is not what it claims must
# never mint an artifact. Which suites are in the set, and why the red ones and
# sync-modules.sh itself are not, is documented in tools/module_gate.sh.
module_gate

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
trap 'shred_key; revert_dispatcher_version; batch_summary' EXIT INT TERM

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
# DISP_NAME — what the bundled dispatcher is CALLED, in the cache and in the
# zip: `burrowee` on stable, `burroweeb` on beta. It is a different binary, not
# a renamed one — it is built with the beta root and the beta per-user prefix
# baked in (tools/build.sh, dispatcher feature 02) — and it has to be a
# different NAME because both end up on one host's PATH, in two different
# roots, at the same time.
DISP_NAME="$(channel_dispatcher "${CHANNEL:-stable}")"

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
    # build_dispatcher <os> <arch> <variant> — idempotent; populates
    # $DISP_DIR/<plat>/burrowee, keyed on the SAME plat_of() every other
    # assembly/publish site uses, so darwin-amd64-legacy caches separately
    # from darwin-amd64 rather than colliding with (and silently reusing) it.
    local os="$1" arch="$2" variant="$3" plat out
    plat="$(plat_of "${os}" "${arch}" "${variant}")"
    out="${DISP_DIR}/${plat}"
    if [ -x "${out}/${DISP_NAME}" ]; then
        # Off darwin, and in every non-Apple mode, the cache means what it always
        # meant: one build per target per run.
        if [ -z "${APPLE_SIGN}" ] || [ "${os}" != darwin ]; then return 0; fi
        if developer_id_signed "${out}/${DISP_NAME}"; then return 0; fi
        echo "→ dispatcher cache ${DISP_STAMP}/${plat} is not Developer-ID signed (an" >&2
        echo "  earlier non-Apple build or --dry-run left it) — rebuilding and re-signing" >&2
        rm -f "${out}/${DISP_NAME}"
    fi
    mkdir -p "${out}"
    # DISPATCHER_NAME + DISPATCHER_ROOT are what make this the BETA dispatcher
    # rather than a copy of the stable one under another name: build.sh bakes
    # the root it resolves system binaries in and the prefix it puts on the
    # per-user ones. On stable both are the defaults and build.sh adds no
    # -X term at all, so the stable dispatcher is byte-for-byte the build it
    # has always been.
    COMP=burrowee SRC_DIR="$(src_for dispatcher)" TARGETOS="${os}" TARGETARCH="${arch}" VARIANT="${variant}" \
        STAMP="${DISP_STAMP}" OUT_DIR="${out}" GO_BIN="${GO_BIN}" \
        DISPATCHER_NAME="${DISP_NAME}" DISPATCHER_ROOT="$(channel_root "${CHANNEL:-stable}")" \
        bash "${REPO_ROOT}/tools/build.sh" >&2
}

# ---- relay private-publish ---------------------------------------------------
do_release_relay() {
    local comp=relay
    local src; src="$(src_for "${comp}")"
    local bins; bins="$(bins_for "${comp}")"

    echo
    echo "=== burrowee relay release (private) ==="

    # (1) stamp — reuse the recorded stamp verbatim (no bump) when relay's
    # source is unchanged since its last cut and the default patch bump is in
    # effect; else bump per BUMP_KIND and mint a fresh stamp. See
    # resolve_comp_stamp() above.
    local old_semver new_semver stamp
    old_semver="$(SRC_DIR="${src}" version_sh "${comp}" --semver)"
    stamp="$(resolve_comp_stamp "${comp}" "${src}")"
    new_semver="$(SRC_DIR="${src}" version_sh "${comp}" --semver)"

    revert_relay_version() {
        local vf="versions/${comp}"
        [ "${CHANNEL}" = beta ] && vf="versions/${comp}.beta"
        git restore --staged "${vf}" 2>/dev/null || true
        git checkout -- "${vf}" 2>/dev/null || true
        git restore --staged "${vf}.stamp" 2>/dev/null || true
        git checkout -- "${vf}.stamp" 2>/dev/null || true
    }
    # ERR INT TERM (not just ERR): a Ctrl-C/SIGTERM after resolve_comp_stamp
    # bumped versions/${comp} must revert it too — mirrors resolve_disp_stamp's
    # dispatcher revert already running on EXIT INT TERM (line ~946). The EXIT
    # trap registered there (shred_key; revert_dispatcher_version) is untouched
    # by this signal-scoped override, so the dispatcher side of cleanup still
    # fires at actual process exit either way.
    trap 'revert_relay_version; shred_key' ERR INT TERM

    # --keep-version arm first: on that path old_semver == new_semver by
    # construction, so without it the run would print "reuse (unchanged, no
    # bump)" — which describes the opposite situation (nothing to ship) and
    # hides the one fact the operator must see, that a live semver is being
    # republished.
    if [ "${KEEP_VERSION}" = 1 ]; then
        echo "Bump    : none — --keep-version REPUBLISHES semver ${new_semver} (already published; only the stamp is new)"
    elif [ "${old_semver}" != "${new_semver}" ]; then
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
    echo "Disp    : ${DISP_STAMP}  (not auto-bumped — bump $(disp_version_rel) manually if the dispatcher source changed)"
    echo "Channel : ${CHANNEL}"
    echo "Dry-run : ${DRY_RUN}"

    local stage="${REPO_ROOT}/dist/${stamp}"
    rm -rf "${stage}"
    mkdir -p "${stage}"

    # (2) per-target build + assemble + zip.
    local zips=() triple os arch variant plat out_bins assemble asset b d
    for triple in "${TARGETS[@]}"; do
        read -r os arch variant <<<"${triple}"
        ships_target "${comp}" "${variant}" || continue
        plat="$(plat_of "${os}" "${arch}" "${variant}")"
        out_bins="${stage}/.bins-${plat}"
        mkdir -p "${out_bins}"

        # dispatcher for this target (built once, reused) — bundled like the public comps.
        build_dispatcher "${os}" "${arch}" "${variant}"

        # relay binaries: build.sh emits all three (serve + cli + updater); the cli
        # and updater get console identity baked (console_pub_hex from
        # config/console-pub.hex). The serve binary gets only -X main.version.
        COMP="${comp}" SRC_DIR="${src}" TARGETOS="${os}" TARGETARCH="${arch}" VARIANT="${variant}" \
            STAMP="${stamp}" OUT_DIR="${out_bins}" GO_BIN="${GO_BIN}" \
            CONSOLE_PUB_HEX="$(console_pub_hex)" \
            bash "${REPO_ROOT}/tools/build.sh" >&2

        # assemble: four binaries (3 relay-tree + dispatcher) + install.sh + the
        # manifest's extras (update.sh + updater.update.sh + the migrations/
        # ladder — shared runner half plus relay's own conf/ledger/rungs). The
        # full installer install.sh is the zip's entrypoint; the extras ride
        # alongside it.
        #
        # install.sh is the ONE member whose provenance is component-specific:
        # relay's comes from its own source tree, the public components' from
        # inner/<comp>/install.sh (do_release, below). That difference lives here at
        # the call site — exactly where cmd/rkit/build.go keeps it — which is what
        # lets everything else come from the shared manifest instead of the
        # open-coded `for s in install.sh update.sh updater.update.sh` this
        # replaces. That list was the last copy of the fact that shipped gateway
        # v0.2.0 with no migrations/ in it.
        assemble="${stage}/burrowee-${comp}-${plat}"
        rm -rf "${assemble}"
        mkdir -p "${assemble}"
        # shellcheck disable=SC2086  # ${bins} is an intentional space-list from bins_for(); word-splitting is the point.
        for b in ${bins}; do cp "${out_bins}/${b}" "${assemble}/${b}"; done
        cp "${DISP_DIR}/${plat}/${DISP_NAME}" "${assemble}/${DISP_NAME}"
        [ -f "${src}/install.sh" ] \
            || { echo "✗ relay script missing in source: ${src}/install.sh" >&2; exit 1; }
        cp "${src}/install.sh" "${assemble}/install.sh"
        chmod 0755 "${assemble}/install.sh"
        stage_payload_extras "${comp}" "${src}" "${assemble}" || exit 1

        # Pre-assembly signing gate: prove every Mach-O in the payload is
        # Developer-ID signed BEFORE it is zipped. Notarization below catches the
        # same thing, but only for darwin, only over the wire, and only after
        # every target is built — and --apple without --public never notarizes at
        # all. See assert_payload_developer_id_signed in tools/apple_sign.sh.
        if [ -n "${APPLE_SIGN}" ]; then
            assert_payload_developer_id_signed "${assemble}" "${os}" || exit 1
        fi

        asset="burrowee-${comp}-${plat}.zip"
        rm -f "${stage}/${asset}"
        ( cd "${assemble}" && zip -j -q "${stage}/${asset}" ./* )
        # zip -j junks paths and SKIPS DIRECTORIES OUTRIGHT, so every
        # directory-shaped payload member needs a second recursive pass — the
        # same loop do_release runs. Since relay took the shared migration
        # ladder (0.2.2 root-only collapse), migrations/ is such a member here
        # too; before that the loop's body never executed and was kept anyway,
        # because its ABSENCE is the defect: gateway/migrations/ went missing
        # precisely because one of two assembly sites had the recursive pass
        # and the other did not.
        for d in $(payload_dir_extras "${comp}"); do
            [ -d "${assemble}/${d}" ] \
                || { echo "✗ ${comp} payload member ${d}/ was never staged: ${assemble}/${d}" >&2; exit 1; }
            ( cd "${assemble}" && zip -r -q "${stage}/${asset}" "${d}/" )
        done
        # Relay payload gate: prove the finished zip carries the ladder — the
        # runner, the libraries, component.conf/ledger, the shared adoption rung
        # relay's own rung delegates to, and every ledger-named script — BEFORE
        # anything is notarized, summed, signed or uploaded. Same gate, same
        # placement as do_release's (see tools/payload.sh).
        assert_payload_migrations "${comp}" "${stage}/${asset}" "${src}" || exit 1

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
    # We name the zips as latest.<plat>.zip so the gate-served paths are
    # stable filenames the installer can hard-code:
    #   /relay/release/latest.darwin-arm64.zip, /relay/release/latest.darwin-amd64-legacy.zip, etc.
    # We also archive a copy under <stamp>/ for the prune-to-3 retention.
    local latest_stage="${REPO_ROOT}/dist/${stamp}/.latest"
    mkdir -p "${latest_stage}"
    for triple in "${TARGETS[@]}"; do
        read -r os arch variant <<<"${triple}"
        ships_target "${comp}" "${variant}" || continue
        plat="$(plat_of "${os}" "${arch}" "${variant}")"
        cp "${stage}/burrowee-${comp}-${plat}.zip" \
           "${latest_stage}/latest.${plat}.zip"
    done
    # SHA256SUMS over the latest.* filenames (what the installer verifies).
    # shellcheck disable=SC2086
    ( cd "${latest_stage}" && ${SHA256} latest.*.zip | sort > SHA256SUMS.txt )
    local tcomment; tcomment="$(trusted_comment "${comp}" "${stamp}")"
    ( cd "${latest_stage}" && minisign -S -s "${SIGN_KEY}" -m SHA256SUMS.txt \
        -t "${tcomment}" >/dev/null )

    echo "Built ${#zips[@]} zips + latest.* set + SHA256SUMS.txt + SHA256SUMS.txt.minisig:"
    # shellcheck disable=SC2012
    ( cd "${latest_stage}" && ls -1 latest.*.zip SHA256SUMS.txt SHA256SUMS.txt.minisig | sed 's/^/    /' )

    # Ask the register binary for the layout rather than rebuilding it here —
    # internal/register/KeyPrefix is the single expression of it. Relay has a
    # beta channel like every other component, so this is "relay/" on stable
    # and "relay/beta/" on beta; the previewed keys below and the success line
    # at the end of this function must both name where the bytes actually go.
    local relay_key_prefix
    relay_key_prefix="$("${REGISTER_BIN}" key-prefix --comp "${comp}" --channel "${CHANNEL}")"

    if [ "${DRY_RUN}" = 1 ]; then
        # Print the would-upload plan (R2 keys, no scp).
        echo ""
        echo "✓ dry-run relay: would upload to R2 under ${relay_key_prefix}${stamp}/"
        echo "  R2 keys:"
        for triple in "${TARGETS[@]}"; do
            read -r os arch variant <<<"${triple}"
            ships_target "${comp}" "${variant}" || continue
            echo "    ${relay_key_prefix}${stamp}/latest.$(plat_of "${os}" "${arch}" "${variant}").zip"
        done
        echo "    ${relay_key_prefix}${stamp}/SHA256SUMS.txt"
        echo "    ${relay_key_prefix}${stamp}/SHA256SUMS.txt.minisig"
        echo "(artifacts under ${latest_stage}/; version bump reverted; no scp)"
        # (9) dry-run registration preview. Unguarded like every other call
        # site: register_staged always returns 0, and a `|| true` here would
        # disable errexit inside its body — so a dry run would stop catching
        # the fail-closed resolution errors (updater_pin above all) that it
        # exists to surface BEFORE a real cut.
        register_staged "${comp}" "${stamp}" "${new_semver}" "${latest_stage}" "${src}"
        revert_relay_version
        trap shred_key ERR INT TERM
        return 0
    fi

    # (4) non-dry-run: upload relay artifacts to R2 under relay/[beta/]<stamp>/.
    # Uses the register tool's publish-relay subcommand which reads R2 creds from
    # ~/.burrowee/release/config.toml + r2.key and verifies sha256 before upload.
    # No scp, no ssh to the release host.
    #
    # --channel is passed, never defaulted: this function fully supports
    # `--channel beta`, and publish-relay's own default is stable. Without it a
    # relay beta cut published to the STABLE prefix — overwriting
    # relay/latest.json with a beta stamp and leaving the artifacts at
    # relay/<stamp>/, which the stable prune skips (the stamp reads "beta") and
    # the beta prune never lists (it lists relay/beta/): unprunable forever.
    "${REGISTER_BIN}" publish-relay \
        --channel "${CHANNEL}" \
        --stamp "${stamp}" \
        --from-dir "${latest_stage}"

    # marker commit (no gh release / no git tag, either channel — relay has
    # always been R2-only). Beta gets the same " beta" marker-subject suffix
    # release.command's push loop matches for the public components.
    local relay_vf="versions/${comp}"
    [ "${CHANNEL}" = beta ] && relay_vf="versions/${comp}.beta"
    git add "${relay_vf}"
    if [ "${CHANNEL}" = beta ]; then
        marker_commit "${REPO_ROOT}" "[RELEASED: ${comp} beta] $(date -u +%Y-%m-%d) ${stamp} (private)"
    else
        marker_commit "${REPO_ROOT}" "[RELEASED: ${comp}] $(date -u +%Y-%m-%d) ${stamp} (private)"
    fi

    # (9) register staged row in the console catalog. Unguarded — see
    # register_staged's header on REG_STAGED_FAILED vs. the return status.
    register_staged "${comp}" "${stamp}" "${new_semver}" "${latest_stage}" "${src}"

    # (10) retention: drain relay R2 prefixes now over keep=3 stable / 1 beta
    # (beta is disposable — the newest cut is the only one kept). Runs HERE,
    # last, and never on the dry-run path (this line is only reachable past
    # the `return 0` in the DRY_RUN branch above, which prints "would: upload"
    # and returns before ever touching R2).
    #
    # It used to run immediately after the publish-relay upload, ahead of the
    # marker commit and this registration. That was the wrong anchor: relay is
    # GATED on every channel, so the console ROW — not the R2 object — is what
    # makes these bytes installable. Draining keep=1 on beta with no row for
    # the new stamp deletes the previous beta and leaves the component with no
    # installable beta at all, and no artifact-level rollback (see keepFor's
    # own doc). Hence both the move and the ${REG_STAGED_FAILED} gate.
    #
    # `|| true` on the drain itself: a retention failure must not fail a relay
    # cut whose artifacts are already up — the nightly com.jc.r2-cleanup agent
    # is the net for that, and for the skipped-drain case below. Relay has no
    # GitHub side to prune, either channel (R2-only).
    echo
    if [ "${REG_STAGED_FAILED}" = 0 ]; then
        echo "→ relay R2 retention (applying):"
        "${REGISTER_BIN}" prune --comp relay --channel "${CHANNEL}" --execute || true
    else
        echo "⚠ relay R2 retention SKIPPED: console registration did not succeed" >&2
        echo "  The artifacts are up but not yet reachable. Register manually, then run:" >&2
        echo "    ${REGISTER_BIN} prune --comp relay --channel ${CHANNEL} --execute" >&2
    fi

    echo "✓ released relay ${stamp} (private, R2 ${relay_key_prefix}${stamp}/)"
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
    old_semver="$(SRC_DIR="${src}" version_sh "${comp}" --semver)"
    stamp="$(resolve_comp_stamp "${comp}" "${src}")"
    new_semver="$(SRC_DIR="${src}" version_sh "${comp}" --semver)"

    # From here the versions/<comp>[.beta](.stamp) files may be modified. Any
    # failure (or the dry-run completion) reverts them.
    revert_version() {
        local vf="versions/${comp}"
        [ "${CHANNEL}" = beta ] && vf="versions/${comp}.beta"
        git restore --staged "${vf}" 2>/dev/null || true
        git checkout -- "${vf}" 2>/dev/null || true
        git restore --staged "${vf}.stamp" 2>/dev/null || true
        git checkout -- "${vf}.stamp" 2>/dev/null || true
    }
    # ERR INT TERM (not just ERR): a Ctrl-C/SIGTERM after resolve_comp_stamp
    # bumped versions/${comp} must revert it too — mirrors resolve_disp_stamp's
    # dispatcher revert already running on EXIT INT TERM (line ~946). The EXIT
    # trap registered there (shred_key; revert_dispatcher_version) is untouched
    # by this signal-scoped override, so the dispatcher side of cleanup still
    # fires at actual process exit either way.
    trap 'revert_version; shred_key' ERR INT TERM

    # --keep-version arm first — see the same block in do_release_relay for why
    # the "reuse (unchanged, no bump)" wording must not be reached on this path.
    if [ "${KEEP_VERSION}" = 1 ]; then
        echo "Bump    : none — --keep-version REPUBLISHES semver ${new_semver} (already published; only the stamp is new)"
    elif [ "${old_semver}" != "${new_semver}" ]; then
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
    echo "Disp    : ${DISP_STAMP}  (not auto-bumped — bump $(disp_version_rel) manually if the dispatcher source changed)"
    echo "Channel : ${CHANNEL}"
    echo "Dry-run : ${DRY_RUN}"

    local stage="${REPO_ROOT}/dist/${stamp}"
    rm -rf "${stage}"
    mkdir -p "${stage}"

    # (3) per-target build + assemble + zip.
    local zips=() triple os arch variant plat out_bins assemble asset b d
    for triple in "${TARGETS[@]}"; do
        read -r os arch variant <<<"${triple}"
        plat="$(plat_of "${os}" "${arch}" "${variant}")"
        out_bins="${stage}/.bins-${plat}"
        mkdir -p "${out_bins}"

        # (2) dispatcher for this target (built once, reused).
        build_dispatcher "${os}" "${arch}" "${variant}"

        # component bins
        if [ "${comp}" = edge ]; then
            COMP="${comp}" SRC_DIR="${src}" TARGETOS="${os}" TARGETARCH="${arch}" VARIANT="${variant}" \
                STAMP="${stamp}" OUT_DIR="${out_bins}" GO_BIN="${GO_BIN}" \
                CONSOLE_PUB_HEX="$(console_pub_hex)" \
                bash "${REPO_ROOT}/tools/build.sh" >&2
        else
            COMP="${comp}" SRC_DIR="${src}" TARGETOS="${os}" TARGETARCH="${arch}" VARIANT="${variant}" \
                STAMP="${stamp}" OUT_DIR="${out_bins}" GO_BIN="${GO_BIN}" \
                bash "${REPO_ROOT}/tools/build.sh" >&2
        fi

        # assemble: component bins + dispatcher + inner installer (→ install.sh)
        assemble="${stage}/burrowee-${comp}-${plat}"
        rm -rf "${assemble}"
        mkdir -p "${assemble}"
        # shellcheck disable=SC2086  # ${bins} is an intentional space-list of bin names from bins_for(); word-splitting is the point.
        for b in ${bins}; do cp "${out_bins}/${b}" "${assemble}/${b}"; done
        cp "${DISP_DIR}/${plat}/${DISP_NAME}" "${assemble}/${DISP_NAME}"
        # The inner installer of THIS CUT'S CHANNEL — inner/<comp>/install.sh on
        # stable, its inner/<comp>/beta.install.sh twin on beta. Resolved through
        # payload.sh's inner_script_src, the same function that picks the
        # channel's updater.install.sh and guard.sh, so one cut cannot ship a
        # beta guard beside a stable installer.
        inner_install="$(inner_script_src "${comp}" install.sh)"
        [ -n "${inner_install}" ] \
            || { echo "✗ no inner installer for ${comp} (channel ${CHANNEL:-stable})" >&2; exit 1; }
        cp "${inner_install}" "${assemble}/install.sh"
        chmod 0755 "${assemble}/install.sh"

        # Cloud-push update scripts: the burrowee-<comp>-updater (and core's Phase-0
        # routing) run `sh ./update.sh` (service update) with cwd = the unzipped
        # bundle, so update.sh MUST ride in the payload alongside the bins. edge +
        # relay additionally self-update via `sh ./updater.update.sh`; gateway + cli
        # self-update in-process (UpgradeSelf binary swap), so they ship update.sh
        # ONLY — no updater.update.sh exists in their source. Without them a pushed
        # update extracts + verifies but then fails "cannot open ./update.sh".
        #
        # WHICH scripts, and the copy itself, are stage_payload_extras in
        # tools/payload.sh — the same manifest cmd/rkit/assemble.go's extraPayload
        # is pinned to by cmd/rkit/payload_manifest_test.go. This site used to
        # restate the list as its own `case`, i.e. a third independent copy of the
        # fact whose second copy shipped gateway v0.2.0 without migrations/.
        stage_payload_extras "${comp}" "${src}" "${assemble}" || exit 1

        # edge decoy covers (copied from the edge.web repo at package time).
        # EDGE_WEB is resolved once, near the top of this file, beside the
        # other REG_*/SRC_* trees, and asserted by assert_release_origins — not
        # re-resolved here.
        if [ "${comp}" = edge ]; then
            mkdir -p "${assemble}/covers"
            cp "${EDGE_WEB}/admin.html" "${assemble}/covers/admin.html"
            cp "${EDGE_WEB}/login.html" "${assemble}/covers/default.html"
        fi

        # gateway migrations/: the ladder runner + every migration, copied from
        # the gateway source. install.sh and update.sh invoke migrations/run.sh
        # out of the unzipped bundle; a payload without it turns a state-moving
        # upgrade into a daemon that comes back without its state.
        # (Mirrors cmd/rkit/assemble.go extraPayload; see tools/payload.sh.)
        if [ "${comp}" = gateway ]; then
            stage_gateway_migrations "${src}" "${assemble}" || exit 1
        fi

        # Pre-assembly signing gate — same assertion as the relay flow above; see
        # assert_payload_developer_id_signed in tools/apple_sign.sh. This is the
        # site that shipped the ad-hoc dispatcher Apple rejected.
        if [ -n "${APPLE_SIGN}" ]; then
            assert_payload_developer_id_signed "${assemble}" "${os}" || exit 1
        fi

        asset="burrowee-${comp}-${plat}.zip"
        rm -f "${stage}/${asset}"
        ( cd "${assemble}" && zip -j -q "${stage}/${asset}" ./* )
        # zip -j junks paths and SKIPS DIRECTORIES OUTRIGHT, so every
        # directory-shaped payload member (edge covers/, gateway migrations/)
        # needs a second recursive pass to keep its path inside the zip. The
        # list is payload_dir_extras in tools/payload.sh — open-coding it per
        # component is exactly how gateway/migrations went missing while
        # edge/covers three lines away was handled.
        for d in $(payload_dir_extras "${comp}"); do
            # A declared member that was never staged would otherwise surface as
            # `zip error: Nothing to do!` — an accurate abort with a message that
            # names neither the component nor the missing directory.
            [ -d "${assemble}/${d}" ] \
                || { echo "✗ ${comp} payload member ${d}/ was never staged: ${assemble}/${d}" >&2; exit 1; }
            ( cd "${assemble}" && zip -r -q "${stage}/${asset}" "${d}/" )
        done
        # Gateway payload gate: prove the finished zip carries migrations/run.sh
        # and every script its ledger names, BEFORE anything is notarized,
        # summed, signed, tagged or published. See tools/payload.sh.
        assert_payload_migrations "${comp}" "${stage}/${asset}" "${src}" || exit 1

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

    # (5) sign. The trusted comment is the release's only version-bearing
    # verified field — see tools/trustcomment.sh, which owns the one shell
    # spelling of it, and cmd/rkit/trusted_comment_test.go, which pins that
    # spelling to rkit's and to the bootstrap's expectation.
    local tcomment; tcomment="$(trusted_comment "${comp}" "${stamp}")"
    ( cd "${stage}" && minisign -S -s "${SIGN_KEY}" -m SHA256SUMS.txt \
        -t "${tcomment}" >/dev/null )

    echo "Built ${#zips[@]} zips + SHA256SUMS.txt + SHA256SUMS.txt.minisig:"
    # shellcheck disable=SC2012  # cosmetic listing of our own controlled asset names (no untrusted filenames); ls keeps the plain one-per-line format.
    ( cd "${stage}" && ls -1 burrowee-"${comp}"-*.zip SHA256SUMS.txt SHA256SUMS.txt.minisig | sed 's/^/    /' )

    # ---- beta channel: private, R2-only publish — NO GitHub Release, NO tag.
    # Diverges here rather than sharing the stable tail below: a beta cut
    # skips gh_release_publish entirely (spec §5.3), so everything past this
    # point (tag, GitHub Release, the stable-only scp block, its marker text,
    # its register_staged gh_tag) is stable-channel-specific.
    if [ "${CHANNEL}" = beta ]; then
        # Ask the register binary for the layout rather than rebuilding it
        # here — internal/register/KeyPrefix is the single expression of it.
        local key_prefix
        key_prefix="$("${REGISTER_BIN}" key-prefix --comp "${comp}" --channel "${CHANNEL}")"

        if [ "${DRY_RUN}" = 1 ]; then
            echo "→ would: publish-dir to R2 under ${key_prefix}${stamp}/ (beta: private until promoted)"
            echo "→ would: gen-bootstraps.sh + scp ${comp}/beta.*.sh (idempotent)"
            echo "→ would: marker commit [RELEASED: ${comp} beta] ${stamp} (private)"
            # (9) dry-run registration preview — the SAME register_staged call
            # the real (non-dry-run) beta branch below makes, not a fourth
            # `would:` line describing it. The four `would:` lines above are a
            # sketch of the beta cut's shape; this builds and prints the
            # actual payload (channel="beta", gated, artifacts keyed under
            # ${comp}/${stamp}/ on R2, github_release forced empty) the same
            # way the stable dry-run above already does, so the one rehearsal
            # an operator runs before a real beta cut previews the real
            # console-registration body instead of a one-line stand-in for
            # it. gh_tag ("") matches the real (non-dry-run) beta call a few
            # lines down: register_staged forces github_release="" for
            # channel=beta regardless of what's passed.
            # Unguarded like every other call site: register_staged always
            # returns 0, and a `|| true` here would disable errexit inside its
            # body — so a dry run would stop catching the fail-closed
            # resolution errors it exists to surface before a real cut.
            register_staged "${comp}" "${stamp}" "${new_semver}" "${stage}" "${src}" ""
            revert_version
            trap shred_key ERR INT TERM
            echo "✓ dry-run ${comp} beta: artifacts under ${stage}/ (version bump reverted; no R2/scp/commit)"
            return 0
        fi

        "${REGISTER_BIN}" publish-dir --comp "${comp}" --channel "${CHANNEL}" --stamp "${stamp}" --from-dir "${stage}"

        # Past the R2 publish — clear the version-revert trap, same reasoning
        # as the stable tail clearing it immediately past gh_release_publish:
        # the upload already happened, so a later failure in this function
        # must not revert the version it was published under.
        trap shred_key ERR INT TERM

        bash "${REPO_ROOT}/tools/gen-bootstraps.sh" >&2
        # Stage every PUBLIC_COMPONENTS dir's beta.*.sh sweep outcome, not
        # only ${comp}'s — same wedge and same fix as do_release()'s stable
        # tail (see the comment there): gen-bootstraps.sh sweeps EVERY public
        # component's beta.*.sh on every invocation, not only THIS comp's. A
        # stale narrower stage left another, already-closed component's sweep
        # deletions unstaged, and release.command's tree_state() refused to
        # push the marker commit this branch makes below — checked only after
        # release.sh returns, by which point the R2 publish-dir a few lines up
        # and the console registration a few lines down have both already run.
        # `-A -- "<dir>"` per component stages whole directories, never the
        # `"${comp}/<artifact>"` shape cmd/rkit's
        # TestReleasePublishesEveryRenderedArtifact's gitAddSites needle
        # matches, and ships nothing (no scp) — not a third publish site.
        for pubcomp in ${PUBLIC_COMPONENTS}; do
            git add -A -- "${pubcomp}"
        done
        # Ship THIS cut's own bootstrap. cmd/rkit's
        # TestReleasePublishesEveryRenderedArtifact requires every rendered
        # artifact scp'd + git-added from EXACTLY two sites; for the beta
        # twins those are here (a real beta cut) and distribute_only (which
        # re-ships the currently-open cycle's twins on every stable
        # distribute, since gen-bootstraps.sh regenerates them regardless of
        # which channel triggered it) — inlined at both, not a shared
        # helper, so a static grep over this file still finds exactly two.
        if [ -f "${REPO_ROOT}/${comp}/beta.install.sh" ]; then
            scp -q "${REPO_ROOT}/${comp}/beta.install.sh" "${RELEASE_HOST}:${STATIC_DIR}/${comp}/beta.install.sh"
        fi
        if [ -f "${REPO_ROOT}/${comp}/beta.upgrade.sh" ]; then
            scp -q "${REPO_ROOT}/${comp}/beta.upgrade.sh" "${RELEASE_HOST}:${STATIC_DIR}/${comp}/beta.upgrade.sh"
        fi
        if [ -f "${REPO_ROOT}/${comp}/beta.updater.install.sh" ]; then
            scp -q "${REPO_ROOT}/${comp}/beta.updater.install.sh" "${RELEASE_HOST}:${STATIC_DIR}/${comp}/beta.updater.install.sh"
        fi

        git add "versions/${comp}.beta" "versions/${comp}.beta.stamp"
        # Both files, not just install.sh: gen-bootstraps.sh renders the pair
        # together, so this should never diverge — but a `git add` of a path
        # that does not exist would abort the cut under `set -e`, and here
        # that would land AFTER the R2 publish and past the cleared
        # revert_version trap, i.e. a published beta with no marker commit.
        if [ -f "${REPO_ROOT}/${comp}/beta.install.sh" ] && [ -f "${REPO_ROOT}/${comp}/beta.upgrade.sh" ]; then
            git add "${comp}/beta.install.sh" "${comp}/beta.upgrade.sh"
        fi
        if [ -f "${REPO_ROOT}/${comp}/beta.updater.install.sh" ]; then
            git add "${comp}/beta.updater.install.sh"
        fi
        marker_commit "${REPO_ROOT}" "[RELEASED: ${comp} beta] $(date -u +%Y-%m-%d) ${stamp} (private)"

        # register_staged with no gh_tag ($6 empty) — channel=beta forces
        # github_release="" regardless (see register_staged), the empty arg
        # here just matches what a beta cut actually has: no GitHub tag.
        # Unguarded — see register_staged's header on why the outcome travels
        # through REG_STAGED_FAILED and not the return status.
        register_staged "${comp}" "${stamp}" "${new_semver}" "${stage}" "${src}" ""

        # Retention runs HERE, after the beta publish AND the console
        # registration above both succeeded — never before, and never on the
        # dry-run path (this line is only reachable past the `return 0` in the
        # DRY_RUN branch above, which returns before the R2 publish-dir call).
        #
        # The ${REG_STAGED_FAILED} gate is the point. A beta artifact is GATED: the
        # console row, not the R2 object, is what makes it installable. Beta
        # retention is keep=1. So an ungated drain after a failed registration
        # deleted the PREVIOUS beta — the only installable one, since the new
        # stamp has no row — leaving the component with no beta at all and no
        # artifact-level rollback (see keepFor's own doc). register_staged
        # warns and returns non-zero on a failed POST precisely so this gate
        # can exist; the cut itself still finishes.
        #
        # Both drains `|| true`: a retention failure must not fail a cut whose
        # artifacts are already up; the nightly com.jc.r2-cleanup agent is the
        # net for that, and for the skipped-drain case below.
        echo
        if [ "${REG_STAGED_FAILED}" = 0 ]; then
            echo "→ beta retention (applying):"
            "${REGISTER_BIN}" prune --comp "${comp}" --channel beta --execute || true
            # GitHub-side beta retention had no caller anywhere in release.sh
            # or release.command before this — beta git tags (minted only
            # later, when the console promotes a staged row to public)
            # accumulated silently past keep=1. tools/prune-releases.sh
            # already defaults KEEP to 1 on beta and reads CHANNEL itself;
            # scope is this one component, matching the R2 call above (a beta
            # cut is always exactly one component — WHAT=all is expanded into
            # a per-component loop before do_release is ever called, see
            # COMPONENTS above). `env -u KEEP`: the script's KEEP default is
            # what must govern an automatic drain, never an operator's ambient
            # export — same strip at every automatic --execute site.
            env -u KEEP CHANNEL=beta COMPONENTS="${comp}" bash "${REPO_ROOT}/tools/prune-releases.sh" --execute || true
        else
            echo "⚠ beta retention SKIPPED (both surfaces): console registration did not succeed" >&2
            echo "  ${comp} beta ${stamp} is in R2 but has no console row, so nothing can install it." >&2
            echo "  Draining keep=1 now would delete the previous beta, the only installable one." >&2
            echo "  Register manually, then run:" >&2
            echo "    ${REGISTER_BIN} prune --comp ${comp} --channel beta --execute" >&2
            echo "    CHANNEL=beta COMPONENTS=${comp} bash tools/prune-releases.sh --execute" >&2
        fi

        echo "✓ released ${comp} beta ${stamp} (private, R2 ${key_prefix}${stamp}/)"
        return 0
    fi
    # ---- stable channel: unchanged from here -----------------------------

    if [ "${DRY_RUN}" = 1 ]; then
        echo "✓ dry-run ${comp}: artifacts under ${stage}/ (version bump reverted; no tag/release/scp)"
        # (9) dry-run registration preview (uses the dry-run stamp for URLs).
        local dry_tag="${comp}/${stamp}"
        # Unguarded — same reason as the beta dry-run preview above.
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
    # Stage — but do NOT ship — whatever gen-bootstraps.sh just did to EVERY
    # public component's beta.*.sh twins, not only THIS comp's. It renders
    # every channel's bootstrap for every component in PUBLIC_COMPONENTS on
    # every invocation, including a stable cut's: re-renders a component's
    # twins while its beta cycle is open (harmless — the bytes don't change
    # unless the pubkey/preflight did) and DELETES them the first time it runs
    # after that component's cycle has just been closed. Nothing about which
    # component gets swept depends on which comp THIS cut is for — so a
    # narrower `git add -A -- "${comp}"` (staging only the comp being cut)
    # left ANOTHER, already-closed component's sweep deletions unstaged: close
    # comp X's cycle (RUNBOOK "Close a cycle" step 1: `git rm
    # versions/X.beta*`), then cut comp Y stable — gen-bootstraps.sh deletes
    # X/beta.*.sh, this block staged only Y's dir, and
    # tools/release.command's tree_state() then refused to push an
    # already-published marker commit ("cut left an unclean tree"), stranding
    # the release AFTER Y's GitHub Release had already gone out — precisely
    # the wedge the original `-A` was added to prevent, just scoped too
    # narrowly to close it. Fix: stage every PUBLIC_COMPONENTS dir, not only
    # ${comp}'s (same list tools/gen-bootstraps.sh sweeps from — see
    # tools/public_components.sh — so the two cannot drift apart again).
    #
    # `-A -- "<dir>"` per component stages adds/modifies/deletes under that
    # dir in one call — it does NOT ship these files (no scp), so it isn't a
    # publish site: it doesn't match cmd/rkit's
    # TestReleasePublishesEveryRenderedArtifact guard, which looks for the
    # literal `git add "${comp}/<artifact>"` form (this loop's pathspec is a
    # bare directory, never `<dir>/<artifact>`), nor does it scp anything.
    # Shipping the twins is still exactly two sites — do_release's
    # CHANNEL=beta branch and distribute_only — this only keeps every
    # component's tree clean after a stable cut's sweep.
    for pubcomp in ${PUBLIC_COMPONENTS}; do
        git add -A -- "${pubcomp}"
    done
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
    # upgrade.sh is install.sh's second mode, rendered from the same template by
    # gen-bootstraps.sh: same pubkey, same preflight pin, same version floor, plus
    # the forced migration pass. It is served from the same directory and MUST be
    # uploaded beside install.sh — a rendered artifact nobody publishes is a 404
    # at a URL we advertise, which is this month's repeated defect in another
    # shape. cmd/rkit's TestReleasePublishesEveryRenderedArtifact pins all four
    # sites (scp + git add, here and in the distribute-only path).
    scp -q "${REPO_ROOT}/${comp}/upgrade.sh" "${RELEASE_HOST}:${STATIC_DIR}/${comp}/upgrade.sh"
    # preflight.sh is a sibling static file the installer fetches before the trust
    # gate (sha256-pinned in install.sh). Ship it alongside install.sh.
    if [ -f "${REPO_ROOT}/${comp}/preflight.sh" ]; then
        scp -q "${REPO_ROOT}/${comp}/preflight.sh" "${RELEASE_HOST}:${STATIC_DIR}/${comp}/preflight.sh"
    fi
    # updater.install.sh is the THIRD @MODE@ of the same template — install.sh's
    # inner script swapped for the narrow updater-recovery script. Rendered by
    # gen-bootstraps.sh for edge/gateway ONLY (see UPDATER_INSTALL_COMPONENTS
    # there), so guarded here the same way preflight.sh is guarded above, not
    # unconditional like install.sh/upgrade.sh which every public component has.
    if [ -f "${REPO_ROOT}/${comp}/updater.install.sh" ]; then
        scp -q "${REPO_ROOT}/${comp}/updater.install.sh" "${RELEASE_HOST}:${STATIC_DIR}/${comp}/updater.install.sh"
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
    git add "versions/${comp}" "${comp}/install.sh" "${comp}/upgrade.sh" "${comp}/preflight.sh"
    # updater.install.sh: same edge/gateway-only guard as its scp above — a
    # `git add` of a path that does not exist for this comp would abort the
    # cut under `set -e`.
    if [ -f "${REPO_ROOT}/${comp}/updater.install.sh" ]; then
        git add "${comp}/updater.install.sh"
    fi
    [ -d "${REPO_ROOT}/skills" ] && git add skills 2>/dev/null || true
    marker_commit "${REPO_ROOT}" "[RELEASED: ${comp}] $(date -u +%Y-%m-%d) ${stamp}"

    # (9) register staged row in the console catalog. Unguarded, like every
    # other call site — a failed POST is reported through REG_STAGED_FAILED,
    # so no `|| true` is needed and none may be added: it would disable
    # errexit inside register_staged's body and let a fail-closed
    # updater_pin/key-prefix/jq error POST a malformed row instead of aborting
    # this cut. No gate needed here either: (10) below is a report, not a
    # drain, and a stable artifact is reachable from its GitHub Release
    # whether or not the console row landed.
    register_staged "${comp}" "${stamp}" "${new_semver}" "${stage}" "${src}" "${tag}"

    # (10) GitHub-release retention (dry-run): report tags now over keep=10. The
    # destructive drain (prune-releases.sh --execute) is a deploy-phase step.
    echo
    echo "→ GitHub release retention (dry-run — run prune-releases.sh --execute in the deploy phase to apply):"
    COMPONENTS="${comp}" bash "${REPO_ROOT}/tools/prune-releases.sh" || true

    echo "✓ released ${tag}"
    echo "  Release: https://github.com/${RELEASE_REPO}/releases/tag/${tag}"
}

# The batch_* calls record what this run got through, so the EXIT trap can say
# which components never ran when a cut dies mid-loop (tools/batch.sh). The
# do_release calls stay BARE on purpose — wrapping them in `if` would suspend
# `set -e` for their whole body and stop unchecked failures inside them from
# aborting the cut.
batch_begin "${COMPONENTS[@]}"
for comp in "${COMPONENTS[@]}"; do
    batch_start "${comp}"
    if [ "${comp}" = relay ]; then
        do_release_relay
    else
        do_release "${comp}"
    fi
    batch_ok "${comp}"
done

# leave dispatcher build cache for inspection on dry-run; clean on real release
if [ "${DRY_RUN}" != 1 ]; then rm -rf "${DISP_DIR}"; fi

echo
echo "✓ done (${WHAT}${DRY_RUN:+, dry-run=${DRY_RUN}})"

#!/usr/bin/env bash
# release.sh — cut a signed Burrowee component release (cli | gateway | edge).
#
# Usage:
#   bash tools/release.sh <cli|gateway|edge|relay|all> [--dry-run] [--bump-minor|--bump-major]
#
# For each requested component this:
#   1. Stamps the version (bump unless --dry-run) via tools/version.sh.
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
# The relay target is a PRIVATE publish (scp to RELAY_PRIVATE_DIR on RELEASE_HOST).
# It does NOT push a GitHub Release, git tag, or update the public site. It does:
#   - Build 4 platform zips + SHA256SUMS.txt + .minisig (same as public comps).
#   - scp zips + SHA256SUMS.txt + .minisig to RELEASE_HOST:RELAY_PRIVATE_DIR/<stamp>/.
#   - Update top-level latest.* set in that dir (latest.<os>-<arch>.zip + SHA256SUMS.txt + .minisig).
#   - Prune stamp dirs to keep the newest 3.
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
#   BURROWEE_SRC_CLI        cli component source worktree (default: cli main worktree)
#   BURROWEE_SRC_GATEWAY    gateway component source worktree
#   BURROWEE_SRC_EDGE       edge component source worktree
#   BURROWEE_SRC_DISPATCHER burrowee dispatcher source worktree
#   BURROWEE_SRC_RELAY      relay component source worktree (default: relay main worktree)
#   RELAY_PRIVATE_DIR       private dir on the release host for relay artifacts
#                           (default /srv/relay-releases)
#   BURROWEE_RELEASE_REPO   GitHub repo for releases (default burrowee-git/release)
#   BURROWEE_RELEASE_YES    skip the interactive minor/major bump confirm
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# ---- go on PATH (the Burrowee per-dir hook strips /opt/homebrew/bin) ---------
GO_BIN="${GO_BIN:-go}"
command -v "${GO_BIN}" >/dev/null 2>&1 || GO_BIN=/opt/homebrew/bin/go
export GO_BIN

# ---- args -------------------------------------------------------------------
WHAT=""
DRY_RUN=0
BUMP_KIND="patch"
for arg in "$@"; do
    case "${arg}" in
        cli|gateway|edge|relay|all) WHAT="${arg}" ;;
        --dry-run)            DRY_RUN=1 ;;
        --bump-minor)         BUMP_KIND="minor" ;;
        --bump-major)         BUMP_KIND="major" ;;
        -h|--help)            sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "✗ unknown argument: ${arg}" >&2; exit 2 ;;
    esac
done
[ -n "${WHAT}" ] || { echo "✗ usage: release.sh <cli|gateway|edge|relay|all> [--dry-run] [--bump-minor|--bump-major]" >&2; exit 2; }

# ---- config / defaults ------------------------------------------------------
RELEASE_HOST="${RELEASE_HOST:-nsm.renative.com}"
STATIC_DIR="${STATIC_DIR:-/ebs_storage/apps/release.burrowee.com/static}"
RELEASE_REPO="${BURROWEE_RELEASE_REPO:-burrowee-git/release}"
DP_DIR="${DP_DIR:-${REPO_ROOT}/../../../release.dp/code/release.dp}"
AGE_KEY_AGE="${DP_DIR}/burrowee-release.key.age"
AGE_IDENTITY="${AGE_IDENTITY:-${HOME}/.age/burrowee-release.txt}"

# component source worktrees (default: each component's MAIN worktree)
BB="/Volumes/MacintoshED/Workstation/Coding/Burrowee"
SRC_CLI="${BURROWEE_SRC_CLI:-${BB}/cli/code/cli}"
SRC_GATEWAY="${BURROWEE_SRC_GATEWAY:-${BB}/gateway/code/gateway}"
SRC_EDGE="${BURROWEE_SRC_EDGE:-${BB}/edge/code/edge}"
SRC_DISPATCHER="${BURROWEE_SRC_DISPATCHER:-${BB}/burrowee/code/burrowee}"
SRC_RELAY="${BURROWEE_SRC_RELAY:-${BB}/relay/code/relay}"
RELAY_PRIVATE_DIR="${RELAY_PRIVATE_DIR:-/srv/relay-releases}"

# edge skills source-of-truth (the edge repo owns these)
EDGE_SKILLS_SRC="${SRC_EDGE}/skills"

TARGETS=(
    "darwin arm64"
    "darwin amd64"
    "linux arm64"
    "linux amd64"
)

src_for() {
    case "$1" in
        cli)     printf '%s' "${SRC_CLI}" ;;
        gateway) printf '%s' "${SRC_GATEWAY}" ;;
        edge)    printf '%s' "${SRC_EDGE}" ;;
        relay)   printf '%s' "${SRC_RELAY}" ;;
    esac
}

# binary list per component (the dispatcher `burrowee` is added at assembly time)
bins_for() {
    case "$1" in
        cli)     printf '%s' "burrowee-cli" ;;
        gateway) printf '%s' "burrowee-gateway burrowee-register" ;;
        edge)    printf '%s' "burrowee-edge burrowee-edge-cli" ;;
        relay)   printf '%s' "burrowee-relay" ;;
    esac
}

GHP="$(command -v ghp 2>/dev/null || echo "${HOME}/.claude/bin/ghp")"

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
# For relay: url_or_key is the host path under RELAY_PRIVATE_DIR/<stamp>/.
# gated=true iff comp==relay. github_release=<comp>/<stamp> for public, ""
# for relay. prerelease=true always.
warn() { echo "⚠ $*" >&2; }
register_staged() {
    local comp="$1" stamp="$2" semver="$3" stage_dir="$4" src_dir="$5"
    local gh_tag="${6:-}"

    local gated=false
    local github_release="${gh_tag}"
    [ "${comp}" = relay ] && gated=true && github_release=""

    json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

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
            url_or_key="${RELAY_PRIVATE_DIR}/${stamp}/${zip_name}"
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

    # sums_ref and minisig_ref: public = GitHub asset URLs; relay = host paths.
    local sums_ref minisig_ref
    if [ "${comp}" = relay ]; then
        sums_ref="${RELAY_PRIVATE_DIR}/${stamp}/SHA256SUMS.txt"
        minisig_ref="${RELAY_PRIVATE_DIR}/${stamp}/SHA256SUMS.txt.minisig"
    else
        sums_ref="https://github.com/${RELEASE_REPO}/releases/download/${gh_tag}/SHA256SUMS.txt"
        minisig_ref="https://github.com/${RELEASE_REPO}/releases/download/${gh_tag}/SHA256SUMS.txt.minisig"
    fi

    local body
    # artifacts is sent as a JSON *string* (console stores it as an opaque JSON blob); object-shaped would 400.
    body="{\"component\":\"$(json_escape "${comp}")\",\"version\":\"$(json_escape "${stamp}")\",\"semver\":\"$(json_escape "${semver}")\",\"gated\":${gated},\"artifacts\":\"$(json_escape "${artifacts_json}")\",\"sums_ref\":\"$(json_escape "${sums_ref}")\",\"minisig_ref\":\"$(json_escape "${minisig_ref}")\",\"github_release\":\"$(json_escape "${github_release}")\",\"prerelease\":true,\"source_sha\":\"$(json_escape "${source_sha}")\",\"sha256\":\"$(json_escape "${sha256_bundle}")\",\"notes\":\"\"}"

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

# ---- pre-flight -------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "✗ required tool not found: $1" >&2; exit 1; }; }
need zip
need unzip
need minisign
command -v "${GO_BIN}" >/dev/null 2>&1 || { echo "✗ go not found (tried '${GO_BIN}')" >&2; exit 1; }

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
    need ghp
    [ -x "${GHP}" ] || { echo "✗ ghp wrapper not found at ${GHP}" >&2; exit 1; }
    "${GHP}" repo view "${RELEASE_REPO}" --json name >/dev/null 2>&1 \
        || { echo "✗ ghp cannot access ${RELEASE_REPO} — check gh.account + auth" >&2; exit 1; }
    ssh -o BatchMode=yes -o ConnectTimeout=5 "${RELEASE_HOST}" 'true' 2>/dev/null \
        || { echo "✗ cannot ssh to ${RELEASE_HOST}" >&2; exit 1; }
    [ -f "${AGE_KEY_AGE}" ] \
        || { echo "✗ release.dp signing key not found: ${AGE_KEY_AGE}" >&2; exit 1; }
fi

# components to cut
if [ "${WHAT}" = all ]; then COMPONENTS=(cli gateway edge); else COMPONENTS=("${WHAT}"); fi

# per-component source-worktree cleanliness + branch (real releases must come
# from a clean `main`; dry-runs are lenient so they can run off a prep worktree).
for comp in "${COMPONENTS[@]}"; do
    src="$(src_for "${comp}")"
    [ -d "${src}" ] || { echo "✗ ${comp} source worktree missing: ${src}" >&2; exit 1; }
    git -C "${src}" rev-parse --git-dir >/dev/null 2>&1 \
        || { echo "✗ ${comp} source is not a git worktree: ${src}" >&2; exit 1; }
    if [ "${DRY_RUN}" != 1 ]; then
        br="$(git -C "${src}" rev-parse --abbrev-ref HEAD)"
        [ "${br}" = main ] || { echo "✗ ${comp} source not on main (on ${br}): ${src}" >&2; exit 1; }
        [ -z "$(git -C "${src}" status --porcelain)" ] \
            || { echo "✗ ${comp} source worktree is dirty: ${src}" >&2; exit 1; }
    fi
done
# relay does not bundle the dispatcher; skip the dispatcher-check for relay-only runs.
relay_only=0
[ "${#COMPONENTS[@]}" = 1 ] && [ "${COMPONENTS[0]}" = relay ] && relay_only=1
if [ "${relay_only}" != 1 ]; then
    [ -d "${SRC_DISPATCHER}" ] || { echo "✗ dispatcher source worktree missing: ${SRC_DISPATCHER}" >&2; exit 1; }
fi

# ---- resolve the signing key ------------------------------------------------
# Sets SIGN_KEY. For the real key we age-decrypt into a chmod-600 tmpfile and
# trap-shred it on EXIT. The TEST key is used as-is for --dry-run.
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
# revert_dispatcher_version restores versions/burrowee when a real release
# bumped it (below) but died before the first component's marker commit staged
# it in. On success the bump is committed (no staged diff) → this is a no-op;
# dry-runs never bump → also a no-op.
revert_dispatcher_version() {
    git -C "${REPO_ROOT}" diff --cached --quiet versions/burrowee 2>/dev/null && return 0
    git -C "${REPO_ROOT}" restore --staged versions/burrowee 2>/dev/null || true
    git -C "${REPO_ROOT}" checkout -- versions/burrowee 2>/dev/null || true
}
trap 'shred_key; revert_dispatcher_version' EXIT INT TERM

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
REGISTER_BIN="${REPO_ROOT}/dist/.tools/burrowee-release-register"
mkdir -p "${REPO_ROOT}/dist/.tools"
echo "→ building burrowee-release-register helper" >&2
"${GO_BIN}" build -buildvcs=false -o "${REGISTER_BIN}" ./cmd/burrowee-release-register \
    || { echo "✗ failed to build burrowee-release-register" >&2; exit 1; }

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
# component zip. Bump its patch once here (real releases only) so it tracks
# releases instead of sitting at 0.1.0 forever — `version.sh --bump-patch`
# stages versions/burrowee, which then rides the first component's [RELEASED]
# marker commit (`git commit` with no pathspec commits all staged files).
if [ "${relay_only}" != 1 ]; then
    if [ "${DRY_RUN}" != 1 ]; then
        SRC_DIR="${SRC_DISPATCHER}" bash "${REPO_ROOT}/tools/version.sh" burrowee --bump-patch >/dev/null
    fi
    DISP_STAMP="$(SRC_DIR="${SRC_DISPATCHER}" bash "${REPO_ROOT}/tools/version.sh" burrowee --stamp)"
    DISP_DIR="${REPO_ROOT}/dist/.dispatcher/${DISP_STAMP}"
fi
build_dispatcher() {
    # build_dispatcher <os> <arch> — idempotent; populates $DISP_DIR/<os>-<arch>/burrowee
    local os="$1" arch="$2" out="${DISP_DIR}/$1-$2"
    if [ -x "${out}/burrowee" ]; then return 0; fi
    mkdir -p "${out}"
    COMP=burrowee SRC_DIR="${SRC_DISPATCHER}" TARGETOS="${os}" TARGETARCH="${arch}" \
        STAMP="${DISP_STAMP}" OUT_DIR="${out}" GO_BIN="${GO_BIN}" \
        bash "${REPO_ROOT}/tools/build.sh" >&2
}

# ---- relay private-publish ---------------------------------------------------
do_release_relay() {
    local src="${SRC_RELAY}"
    local comp=relay

    echo
    echo "=== burrowee relay release (private) ==="

    # (1) stamp — bump unless dry-run.
    local old_semver new_semver stamp
    old_semver="$(SRC_DIR="${src}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --semver)"
    if [ "${DRY_RUN}" = 1 ]; then
        stamp="$(SRC_DIR="${src}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --stamp)"
        new_semver="${old_semver}"
    else
        case "${BUMP_KIND}" in
            patch) SRC_DIR="${src}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --bump-patch >/dev/null ;;
            minor) SRC_DIR="${src}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --bump-minor >/dev/null ;;
            major) SRC_DIR="${src}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --bump-major >/dev/null ;;
        esac
        new_semver="$(SRC_DIR="${src}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --semver)"
        stamp="$(SRC_DIR="${src}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --stamp)"
    fi

    revert_relay_version() {
        git restore --staged "versions/${comp}" 2>/dev/null || true
        git checkout -- "versions/${comp}" 2>/dev/null || true
    }
    trap 'revert_relay_version; shred_key' ERR

    echo "Bump    : ${BUMP_KIND} (${old_semver} → ${new_semver})"
    echo "Stamp   : ${stamp}"
    echo "Source  : ${src} @ $(git -C "${src}" rev-parse --short=8 HEAD)"
    echo "Dry-run : ${DRY_RUN}"

    local stage="${REPO_ROOT}/dist/${stamp}"
    rm -rf "${stage}"
    mkdir -p "${stage}"

    # (2) per-target build + assemble + zip.
    local zips=() pair os arch out_bins assemble asset b
    for pair in "${TARGETS[@]}"; do
        read -r os arch <<<"${pair}"
        out_bins="${stage}/.bins-${os}-${arch}"
        mkdir -p "${out_bins}"

        COMP="${comp}" SRC_DIR="${src}" TARGETOS="${os}" TARGETARCH="${arch}" \
            STAMP="${stamp}" OUT_DIR="${out_bins}" GO_BIN="${GO_BIN}" \
            bash "${REPO_ROOT}/tools/build.sh" >&2

        # assemble: component bin + inner installer (→ install.sh). NO dispatcher.
        assemble="${stage}/burrowee-${comp}-${os}-${arch}"
        rm -rf "${assemble}"
        mkdir -p "${assemble}"
        # shellcheck disable=SC2086
        for b in burrowee-relay; do cp "${out_bins}/${b}" "${assemble}/${b}"; done
        cp "${REPO_ROOT}/inner/${comp}/install.sh" "${assemble}/install.sh"
        chmod 0755 "${assemble}/install.sh"

        asset="burrowee-${comp}-${os}-${arch}.zip"
        rm -f "${stage}/${asset}"
        ( cd "${assemble}" && zip -j -q "${stage}/${asset}" ./* )
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
        # Print the would-scp / would-prune plan.
        echo ""
        echo "✓ dry-run relay: would publish to ${RELEASE_HOST}:${RELAY_PRIVATE_DIR}"
        echo "  stamp dir  : ${RELAY_PRIVATE_DIR}/${stamp}/"
        echo "  scp files  :"
        for pair in "${TARGETS[@]}"; do
            read -r os arch <<<"${pair}"
            echo "    latest.${os}-${arch}.zip → ${RELAY_PRIVATE_DIR}/${stamp}/"
        done
        echo "    SHA256SUMS.txt → ${RELAY_PRIVATE_DIR}/${stamp}/"
        echo "    SHA256SUMS.txt.minisig → ${RELAY_PRIVATE_DIR}/${stamp}/"
        echo "  latest.* update :"
        for pair in "${TARGETS[@]}"; do
            read -r os arch <<<"${pair}"
            echo "    latest.${os}-${arch}.zip → ${RELAY_PRIVATE_DIR}/"
        done
        echo "    SHA256SUMS.txt → ${RELAY_PRIVATE_DIR}/"
        echo "    SHA256SUMS.txt.minisig → ${RELAY_PRIVATE_DIR}/"
        echo "  prune: would list ${RELAY_PRIVATE_DIR}/ → keep newest 3 stamp dirs, delete rest"
        echo "(artifacts under ${stage}/; version bump reverted; no scp/ssh)"
        # (9) dry-run registration preview.
        register_staged "${comp}" "${stamp}" "${new_semver}" "${latest_stage}" "${src}"
        revert_relay_version
        trap shred_key ERR
        return 0
    fi

    # (4) non-dry-run: scp stamp dir + update latest.* + prune.
    # pre-flight: ssh check already done above in the non-relay path, but relay
    # uses the same RELEASE_HOST; verify it's still reachable.
    ssh -o BatchMode=yes -o ConnectTimeout=5 "${RELEASE_HOST}" 'true' 2>/dev/null \
        || { echo "✗ cannot ssh to ${RELEASE_HOST}" >&2; exit 1; }

    # shellcheck disable=SC2029
    ssh "${RELEASE_HOST}" "mkdir -p '${RELAY_PRIVATE_DIR}/${stamp}'"
    # scp stamp copies (archived versions: latest-named zips + sums)
    # The SHA256SUMS.txt covers latest.<os>-<arch>.zip filenames, so the stamp
    # dir carries the latest-named copies too — making it internally consistent
    # (the stamped burrowee-relay-<os>-<arch>.zip names are for local retention
    # only and are NOT referenced by SHA256SUMS.txt).
    for pair in "${TARGETS[@]}"; do
        read -r os arch <<<"${pair}"
        scp -q "${latest_stage}/latest.${os}-${arch}.zip" \
            "${RELEASE_HOST}:${RELAY_PRIVATE_DIR}/${stamp}/latest.${os}-${arch}.zip"
    done
    scp -q "${latest_stage}/SHA256SUMS.txt" \
        "${RELEASE_HOST}:${RELAY_PRIVATE_DIR}/${stamp}/SHA256SUMS.txt"
    scp -q "${latest_stage}/SHA256SUMS.txt.minisig" \
        "${RELEASE_HOST}:${RELAY_PRIVATE_DIR}/${stamp}/SHA256SUMS.txt.minisig"

    # update top-level latest.* set (atomic enough — each file overwritten in place)
    for pair in "${TARGETS[@]}"; do
        read -r os arch <<<"${pair}"
        scp -q "${latest_stage}/latest.${os}-${arch}.zip" \
            "${RELEASE_HOST}:${RELAY_PRIVATE_DIR}/latest.${os}-${arch}.zip"
    done
    scp -q "${latest_stage}/SHA256SUMS.txt" \
        "${RELEASE_HOST}:${RELAY_PRIVATE_DIR}/SHA256SUMS.txt"
    scp -q "${latest_stage}/SHA256SUMS.txt.minisig" \
        "${RELEASE_HOST}:${RELAY_PRIVATE_DIR}/SHA256SUMS.txt.minisig"

    # prune: keep newest 3 stamp dirs
    # shellcheck source=tools/prune_releases_keep.sh
    . "${REPO_ROOT}/tools/prune_releases_keep.sh"
    # list stamp dirs on the remote (lines like "v0.1.0.2026.06.17.abc12345")
    # shellcheck disable=SC2029
    remote_stamps="$(ssh "${RELEASE_HOST}" "find '${RELAY_PRIVATE_DIR}' -maxdepth 1 -type d -name 'v*' -printf '%f\n'" 2>/dev/null || true)"
    if [ -n "${remote_stamps}" ]; then
        # shellcheck disable=SC2086
        to_delete="$(keep_latest 3 ${remote_stamps})"
        if [ -n "${to_delete}" ]; then
            while IFS= read -r d; do
                [ -n "${d}" ] || continue
                echo "→ pruning ${RELAY_PRIVATE_DIR}/${d}" >&2
                # shellcheck disable=SC2029
                ssh "${RELEASE_HOST}" "rm -rf '${RELAY_PRIVATE_DIR}/${d}'"
            done <<<"${to_delete}"
        fi
    fi

    # marker commit (no gh release / no git tag)
    git add "versions/${comp}"
    git commit -m "[RELEASED: ${comp}] $(date -u +%Y-%m-%d) ${stamp} (private)"

    # (9) register staged row in the console catalog.
    register_staged "${comp}" "${stamp}" "${new_semver}" "${latest_stage}" "${src}"

    echo "✓ released relay ${stamp} (private, ${RELAY_PRIVATE_DIR})"
    trap shred_key ERR
}

# ---- per-component release --------------------------------------------------
do_release() {
    local comp="$1"
    local src; src="$(src_for "${comp}")"
    local bins; bins="$(bins_for "${comp}")"

    echo
    echo "=== burrowee ${comp} release ==="

    # (1) stamp — bump unless dry-run.
    local old_semver new_semver stamp
    old_semver="$(SRC_DIR="${src}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --semver)"
    if [ "${DRY_RUN}" = 1 ]; then
        stamp="$(SRC_DIR="${src}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --stamp)"
        new_semver="${old_semver}"
    else
        case "${BUMP_KIND}" in
            patch) SRC_DIR="${src}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --bump-patch >/dev/null ;;
            minor) SRC_DIR="${src}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --bump-minor >/dev/null ;;
            major) SRC_DIR="${src}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --bump-major >/dev/null ;;
        esac
        new_semver="$(SRC_DIR="${src}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --semver)"
        stamp="$(SRC_DIR="${src}" bash "${REPO_ROOT}/tools/version.sh" "${comp}" --stamp)"
    fi

    # From here the versions/<comp> file may be modified. Any failure (or the
    # dry-run completion) reverts it.
    revert_version() {
        git restore --staged "versions/${comp}" 2>/dev/null || true
        git checkout -- "versions/${comp}" 2>/dev/null || true
    }
    trap 'revert_version; shred_key' ERR

    echo "Bump    : ${BUMP_KIND} (${old_semver} → ${new_semver})"
    echo "Stamp   : ${stamp}"
    echo "Source  : ${src} @ $(git -C "${src}" rev-parse --short=8 HEAD)"
    echo "Disp    : ${DISP_STAMP}"
    echo "Dry-run : ${DRY_RUN}"

    local stage="${REPO_ROOT}/dist/${stamp}"
    rm -rf "${stage}"
    mkdir -p "${stage}"

    # (3) per-target build + assemble + zip.
    local zips=() pair os arch out_bins assemble asset b
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

        # edge decoy covers (copied from the edge.web repo at package time)
        if [ "${comp}" = edge ]; then
            EDGE_WEB="${EDGE_WEB_DIR:-${BB}/edge.web/code/edge.web}"
            mkdir -p "${assemble}/covers"
            cp "${EDGE_WEB}/admin.html" "${assemble}/covers/admin.html"
            cp "${EDGE_WEB}/login.html" "${assemble}/covers/default.html"
        fi

        asset="burrowee-${comp}-${os}-${arch}.zip"
        rm -f "${stage}/${asset}"
        ( cd "${assemble}" && zip -j -q "${stage}/${asset}" ./* )
        # Edge payload carries covers/ — zip -j skips directories, so append them
        # recursively to preserve the covers/ path inside the zip.
        if [ "${comp}" = edge ]; then
            ( cd "${assemble}" && zip -r -q "${stage}/${asset}" covers/ )
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
        trap shred_key ERR
        return 0
    fi

    # (6) tag + GitHub Release.
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

    # Past the tag/release — clear the version-revert trap.
    trap shred_key ERR

    # (7) regenerate bootstraps + refresh edge skills + scp the static surface.
    bash "${REPO_ROOT}/tools/gen-bootstraps.sh" >&2
    # Edge skills are OWNED by the edge repo; mirror them in from its worktree on
    # every release so the served copy can never drift from source. (The cli +
    # gateway skills are authored in THIS repo and are left untouched.) Fail loudly
    # if the edge source is gone — a stale snapshot must not ship silently.
    [ -d "${EDGE_SKILLS_SRC}" ] \
        || { echo "✗ edge skills source missing: ${EDGE_SKILLS_SRC} (set BURROWEE_SRC_EDGE)" >&2; exit 1; }
    mkdir -p "${REPO_ROOT}/skills"
    for d in "${EDGE_SKILLS_SRC}"/burrowee-edge-*; do
        [ -d "${d}" ] || continue
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
if [ "${DRY_RUN}" != 1 ] && [ "${relay_only}" != 1 ]; then rm -rf "${DISP_DIR}"; fi

echo
echo "✓ done (${WHAT}${DRY_RUN:+, dry-run=${DRY_RUN}})"

#!/bin/sh
# Burrowee outer bootstrap — THE TRUST ANCHOR (POSIX sh, macOS + Linux).
#
#   curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/edge/install.sh | sh
#
# This is the stable, curl'd-alone entry point for the `edge` component
# (which bundles the `burrowee` dispatcher). It NEVER runs an unverified byte:
# it downloads the release zip + SHA256SUMS.txt + its minisig, verifies the
# minisign signature with a baked-in PUBLIC key, verifies the zip's sha256
# against the now-trusted sums file, and ONLY THEN unzips and execs the inner
# per-release install.sh. Any failure aborts before anything is installed.
#
# DO NOT EDIT generated copies (edge/install.sh) by hand — they are produced
# from tools/bootstrap.template.sh by tools/gen-bootstraps.sh.
#
# Env vars:
#   BURROWEE_<COMP>_VERSION      pin a release tag (e.g. edge/v0.1.0.…); default: latest
#                                (<COMP> = the component name upper-cased, e.g. BURROWEE_CLI_VERSION)
#   PREFIX                       install root (default $HOME/.local; bins at PREFIX/bin)
#   BURROWEE_UNINSTALL=1         pass through to the inner installer to remove bins
#   BURROWEE_RELEASE_REPO        GitHub repo serving releases (default burrowee-git/release)
#   BURROWEE_SKIP_PREFLIGHT=1    skip the OS-dependency preflight (manage deps yourself)
#   BURROWEE_SKIP_NGINX=1        (edge) skip nginx + stream module in the preflight
#   BURROWEE_NO_PATH_EDIT=1      do not persist PREFIX/bin to your shell rc
#   BURROWEE_CHANNEL_BASE        base URL for the static channel (preflight.sh lives here)
#   BURROWEE_DL_BASE             (test hook) download assets from this base instead of GitHub
#   CONSOLE_URL                  Burrowee console base URL; used by the R2 fallback when
#                                GitHub is unreachable (default https://console.burrowee.com)
#   BURROWEE_GH_PROXY            Space-separated list of GitHub HTTP mirrors, tried in order
#                                ONLY when github.com / api.github.com are unreachable
#                                (default: gh-proxy.org cdn.gh-proxy.org v6.gh-proxy.org
#                                gh-proxy.com; set empty to disable). Downloaded bytes are
#                                minisign + sha256 verified and bound to the resolved tag,
#                                so a mirror cannot tamper. A mirror that also RESOLVES the
#                                tag (GitHub's API down) is additionally held to the version
#                                floor baked into this installer — see "version floor" below.

set -eu

# ---- knobs --------------------------------------------------------------
COMP="edge"
PUBKEY="RWT/O8xU4IbIBI1rg1T9ddsPLqdhI7wOYaVPDt/9ctT2TkNI2H2yLXFk"
PREFLIGHT_SHA256="20aff889401bbf192b378941923f58fd934f459b930436a3f225ba199b539e18"
# The version floor: the stamp this component was at when THIS installer was
# generated and published (baked from versions/<comp>.stamp by
# tools/gen-bootstraps.sh, which release.sh re-runs on every cut). A tag
# resolved from GitHub — or from a GH_PROXY mirror standing in for it — must be
# at least this version; see "version floor" below (the first-party console
# catalog is exempt, for the reason spelled out at the resolution choke point).
# It rides the same first-party static channel, over the same TLS fetch, that
# delivered $PUBKEY, so it costs no trust the installer did not already require;
# and no download source gets to choose it.
MIN_VERSION="v0.1.109.2026.08.04.2f97669e"
REPO="${BURROWEE_RELEASE_REPO:-burrowee-git/release}"
PREFIX="${PREFIX:-$HOME/.local}"
DL_BASE="${BURROWEE_DL_BASE:-}"           # test hook (undocumented to users)
# Static channel base (where preflight.sh lives — a sibling static file, NOT a
# GitHub release asset). $COMP is a baked literal, safe to interpolate.
CHANNEL_BASE="${BURROWEE_CHANNEL_BASE:-https://release.burrowee.com/$COMP}"
# Console base for R2 fallback (version catalog + presigned asset URLs via
# `burrowee download-url`). Only used when GitHub is unreachable AND the host
# has an authorized `burrowee` with a device grant.
CONSOLE_URL="${CONSOLE_URL:-https://console.burrowee.com}"
# GitHub HTTP mirrors, tried in order ONLY as a fallback when github.com /
# api.github.com are unreachable (e.g. networks that block or throttle GitHub).
# Each is tried as <mirror>/<original-https-github-url> until one succeeds.
#
# What the mirrors CANNOT do: inject tampered bytes. The downloaded bytes are
# minisign- + sha256-verified below and bound to $TAG via the SIGNED trusted
# comment.
#
# What that binding does NOT cover on its own: when the GitHub API is also
# unreachable, the tag itself is resolved from a mirror — so the binding would
# be comparing the mirror's own answer against itself, and any older, genuinely
# signed release would pass every gate. The version floor (see below) is what
# constrains that answer: a mirror can at worst hold you at the version the
# first-party channel advertised when you fetched this installer, and cannot
# walk you back to an arbitrary older signed release. Space-separated list.
# ${VAR-default} (not :-) lets `BURROWEE_GH_PROXY=` explicitly disable the
# mirrors while an unset value gets the default. Never used when DL_BASE is set.
GH_PROXIES="${BURROWEE_GH_PROXY-https://gh-proxy.org https://cdn.gh-proxy.org https://v6.gh-proxy.org https://gh-proxy.com}"

# Production downloads are pinned to HTTPS/TLS1.2 (--proto =https). The
# BURROWEE_DL_BASE test hook points at a local plain-HTTP server, so when it is
# set we drop the TLS-only flags (they'd reject http://); the version-pin guard
# below keeps even that path scheme-locked to the test base.
#
# --speed-limit/--speed-time abort a STALLED transfer (< ~4 KB/s for 20s) instead
# of hanging until --max-time. This matters for the gh-proxy mirror loop: a mirror
# that streams a few MB then stalls is abandoned in ~20s so the NEXT mirror is
# tried, rather than the install appearing stuck for the full 5-minute max-time.
if [ -n "$DL_BASE" ]; then
    CURL="curl -fsSL --connect-timeout 15 --max-time 300 --speed-limit 4096 --speed-time 20"
else
    CURL="curl -fsSL --proto =https --tlsv1.2 --connect-timeout 15 --max-time 300 --speed-limit 4096 --speed-time 20"
fi

# ---- helpers ------------------------------------------------------------
fail() { printf '\n  ✗ %s\n\n' "$*" >&2; exit 1; }
info() { printf '  → %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else return 1; fi
}

# BEGIN release-resolver  (tools/test-version-floor.sh extracts this block — and
# the version-resolve block further down — verbatim and drives them against a
# stub $CURL; keep both self-contained between their markers, and keep the
# markers.)
#
# Extract the highest "<comp>/v<semver>" tag from a GitHub /releases JSON body
# read on stdin. The /releases order is by tag-commit date, NOT publish order,
# so it is unreliable for "latest" — pick the highest tag via version sort.
# Match only the real "tag_name" FIELD (line-anchored) so release-notes/body
# text that merely contains the literal `"tag_name"` can't spoof the tag.
# Prefer jq (structural); fall back to grep/sed. Used for both the direct
# api.github.com fetch and the GH_PROXY mirror retry.
latest_tag() {
    if command -v jq >/dev/null 2>&1; then
        jq -r '.[].tag_name // empty' 2>/dev/null
    else
        grep -E '^[[:space:]]*"tag_name"[[:space:]]*:' \
            | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
    fi | grep -E "^${COMP}/v" | sort -V | tail -n1
}

# next_page_url — read a `curl -D` header dump on stdin and print the URL from
# `Link: <…>; rel="next"`, or nothing when this was the last page. Only an
# api.github.com URL is accepted: the header may have been written by a GH_PROXY
# mirror, and a mirror must not get to walk the resolver onto a host of its own
# choosing. (curl -L appends one header block per hop, so take the LAST Link.)
next_page_url() {
    _np="$(tr -d '\r' \
        | grep -i '^link:' \
        | tr ',' '\n' \
        | grep 'rel="next"' \
        | sed -E 's/.*<([^>]*)>.*/\1/' \
        | tail -n1)"
    case "$_np" in
        https://api.github.com/*) printf '%s' "$_np" ;;
    esac
}

# resolve_latest <url-prefix> — the highest "<comp>/v…" tag across EVERY page of
# the repo's release list, following the `Link: rel="next"` header. <url-prefix>
# is "" for a direct api.github.com fetch, or "<mirror>/" to route each page
# through a GH_PROXY mirror.
#
# Why the pages matter: /releases serves at most 100 entries per page and this
# repo publishes every component into ONE list. The moment a quiet component's
# newest release scrolls off page 1, a single-page fetch answers with an OLDER
# release OF THAT COMPONENT — not with nothing — and every downstream check
# still passes, because those bytes are a genuine signed release. That is the
# same stale-answer hazard the version floor exists for, except the installer
# produced it itself, so the floor turns it into an install that cannot succeed
# at all without a manual pin. Walk the whole list instead.
#
# Returns 1 if ANY page fetch fails: a partial walk can only answer too low, and
# the caller has better options (the mirrors, then the console catalog) than a
# stale tag.
resolve_latest() {
    _rl_prefix="$1"
    _rl_url="https://api.github.com/repos/${REPO}/releases?per_page=100"
    _rl_pages=0
    : > "$TMP/tags"
    while [ -n "$_rl_url" ]; do
        _rl_pages=$((_rl_pages + 1))
        # shellcheck disable=SC2086  # $CURL is an intentional space-split command string (flags + binary); POSIX sh has no arrays.
        $CURL -D "$TMP/page.head" -o "$TMP/page.json" "${_rl_prefix}${_rl_url}" 2>/dev/null \
            || return 1
        latest_tag < "$TMP/page.json" >> "$TMP/tags"
        # 20 pages = 2000 releases, far past this repo's list; the cap only
        # bounds a source that keeps handing out a "next" link forever.
        [ "$_rl_pages" -lt 20 ] || break
        _rl_url="$(next_page_url < "$TMP/page.head")"
    done
    sort -V < "$TMP/tags" | tail -n1
}
# END release-resolver

# ---- version floor helpers ----------------------------------------------
# BEGIN version-floor  (tools/test-version-floor.sh extracts this block verbatim
# and exercises it directly — keep it self-contained between the markers, and
# keep the markers.)
#
# semver_of <stamp> — the leading X.Y.Z of a release stamp (vX.Y.Z.<date>.<sha8>).
# ONLY the semver is compared: release.sh bumps it monotonically on every cut,
# whereas the date and changeset suffixes are not ordered text (two stamps that
# differ only in changeset would compare arbitrarily).
semver_of() {
    printf '%s' "${1#v}" | cut -d. -f1-3
}

# is_semver <x> — true only for a bare numeric X.Y.Z. Everything else (empty,
# an unsubstituted @…@ placeholder, a tag shape we don't understand) is NOT a
# version and must never be compared as one.
is_semver() {
    case "$1" in
        [0-9]*.[0-9]*.[0-9]*) ;;
        *) return 1 ;;
    esac
    case "$1" in
        *[!0-9.]*) return 1 ;;
    esac
    return 0
}

# version_ge <a> <b> — true when semver(a) >= semver(b). Fails CLOSED: if either
# side is not a well-formed semver, the answer is "no".
version_ge() {
    _vg_a="$(semver_of "$1")"
    _vg_b="$(semver_of "$2")"
    is_semver "$_vg_a" || return 1
    is_semver "$_vg_b" || return 1
    if [ "$_vg_a" = "$_vg_b" ]; then return 0; fi
    [ "$(printf '%s\n%s\n' "$_vg_a" "$_vg_b" | sort -V | head -n1)" = "$_vg_b" ]
}

# assert_version_floor <tag> — abort unless <tag> is at least $MIN_VERSION.
#
# <tag> here was answered by GITHUB, and when api.github.com is unreachable the
# party that answered is a GH_PROXY mirror standing in for it — the very same
# party that then serves the artifacts. (The console catalog resolves versions
# too, but is exempt from this floor and never reaches here; the version-resolve
# block says why.) The trusted-comment binding
# further down compares the signed comment against the tag, so on that path it
# compares the resolver's answer against itself: an older, genuinely signed
# triple (zip + sums + minisig, all mutually consistent, all really ours) passes
# every remaining gate. That is a silent rollback onto a known-vulnerable build,
# and no amount of signature checking can catch it, because nothing about those
# bytes is wrong — only the choice of WHICH release was wrong.
#
# $MIN_VERSION is the floor the resolver does not get to choose: the stamp this
# component was at when this installer was generated and published. It reached
# this host over the first-party static channel, in the same fetch that
# delivered $PUBKEY — an attacker who can forge it can already forge the signing
# key, so it adds no trust assumption.
#
# The exact property this buys, and the strongest one available without a signed
# version catalog: a hostile resolver can at worst pin you to the version the
# first-party channel itself advertised when you fetched this installer. It
# cannot walk you back any further.
assert_version_floor() {
    case "$MIN_VERSION" in
        ""|*@*|*PLACEHOLDER*|*TEMP*)
            fail "no version floor baked into this installer — refusing to accept a network-resolved version with nothing to check it against (regenerate with tools/gen-bootstraps.sh, or pin the version yourself via the BURROWEE_<COMP>_VERSION env var)" ;;
    esac
    version_ge "${1#*/}" "$MIN_VERSION" \
        || fail "version floor not met — resolved \"$1\", but this installer was published at \"$MIN_VERSION\" and will not go backwards.
    Refusing to install: this is what a mirror serving a stale, older (but
    genuinely signed) release looks like. Retry when github.com is reachable, or
    pin the version you actually want via the environment and install again."
    ok "version floor satisfied ($MIN_VERSION)"
}
# END version-floor

# ---- platform detection -------------------------------------------------
case "$(uname -s)" in
    Darwin) OS=darwin ;;
    Linux)  OS=linux ;;
    *)      fail "unsupported OS: $(uname -s) (burrowee ships darwin + linux only)" ;;
esac
case "$(uname -m)" in
    arm64|aarch64) ARCH=arm64 ;;
    x86_64|amd64)  ARCH=amd64 ;;
    *)             fail "unsupported arch: $(uname -m) (burrowee ships arm64 + amd64 only)" ;;
esac

printf '\n  burrowee %s installer  (%s/%s)\n\n' "$COMP" "$OS" "$ARCH"

# ---- guard against a TEMP / unbaked pubkey ------------------------------
case "$PUBKEY" in
    ""|*REPLACE*|*PLACEHOLDER*|*TEMP*)
        fail "this installer was built without a real signing key — refusing to verify against a placeholder (regenerate with tools/gen-bootstraps.sh)" ;;
esac

# ---- temp workspace -----------------------------------------------------
TMP="$(mktemp -d "${TMPDIR:-/tmp}/burrowee-${COMP}-XXXXXX")" || fail "could not create temp dir"
trap 'rm -rf "$TMP"' EXIT INT TERM

# ---- preflight (install OS deps before the trust gate) ------------------
# preflight.sh installs minisign/unzip/curl (the trust gate's deps) + nginx for
# edge, with root, from the OS package manager. It runs BEFORE `require minisign`.
# It is fetched from the static CHANNEL_BASE (a sibling static file, NOT a GitHub
# release asset), and verified against a baked sha256 — there is no minisign yet,
# so the sha256 pin is the integrity anchor (preflight only invokes the OS package
# manager, whose repos are themselves signed). Skipped on uninstall or via env.
if [ -z "${BURROWEE_UNINSTALL:-}" ] && [ -z "${BURROWEE_SKIP_PREFLIGHT:-}" ]; then
    info "preflight: ensuring OS dependencies"
    PF_BASE="${DL_BASE:-$CHANNEL_BASE}"
    # shellcheck disable=SC2086
    $CURL -o "$TMP/preflight.sh" "$PF_BASE/preflight.sh" \
        || fail "could not download preflight.sh from $PF_BASE — set BURROWEE_SKIP_PREFLIGHT=1 to install deps yourself"
    case "$PREFLIGHT_SHA256" in
        ""|*PLACEHOLDER*|*TEMP*) fail "preflight checksum not baked — regenerate with tools/gen-bootstraps.sh" ;;
    esac
    pf_got="$(sha256_of "$TMP/preflight.sh")" || fail "cannot checksum preflight (need shasum or sha256sum)"
    [ "$pf_got" = "$PREFLIGHT_SHA256" ] \
        || fail "preflight.sh checksum mismatch (expected $PREFLIGHT_SHA256, got $pf_got) — refusing to run a tampered preflight"
    ok "preflight verified"
    sh "$TMP/preflight.sh" || info "preflight could not complete fully — continuing; the trust gate will verify required tools"
fi

# ---- version resolution -------------------------------------------------
# BEGIN version-resolve
# Read the per-component pin env var by name (no eval). $COMP is a baked
# literal, so a direct case over the four known components is exhaustive.
case "$COMP" in
    cli)     PIN="${BURROWEE_CLI_VERSION:-}" ;;
    gateway) PIN="${BURROWEE_GATEWAY_VERSION:-}" ;;
    edge)    PIN="${BURROWEE_EDGE_VERSION:-}" ;;
    agent)   PIN="${BURROWEE_AGENT_VERSION:-}" ;;
    *)       fail "unknown component '$COMP' — cannot resolve its version pin" ;;
esac
# An explicit pin is the operator's own answer, not a resolver's — it is used
# verbatim and is NOT held to the version floor below. Pinning an older release
# is a deliberate, local downgrade (debugging, staged rollback); refusing it
# would take away the only lever an operator has when a new cut misbehaves.
if [ -n "$PIN" ]; then
    TAG="$PIN"
    info "using pinned version: $TAG"
else
    info "resolving latest ${COMP} release"
    # Who answered? "github" = api.github.com, or a GH_PROXY mirror standing in
    # for it; "catalog" = the first-party console. Only the github answer is held
    # to the version floor — see the choke point at the end of this block.
    TAG_SOURCE=github
    TAG="$(resolve_latest '')" || TAG=""
    # GitHub API unreachable/empty — retry through each mirror in turn BEFORE the
    # console catalog (mirrors need no authorized burrowee, so they serve fresh
    # hosts). Skipped under the DL_BASE test hook and when mirrors are disabled.
    if [ -z "$TAG" ] && [ -z "$DL_BASE" ] && [ -n "$GH_PROXIES" ]; then
        for _proxy in $GH_PROXIES; do
            info "GitHub API unreachable — retrying via mirror $_proxy"
            TAG="$(resolve_latest "$_proxy/")" || TAG=""
            if [ -n "$TAG" ]; then info "mirror resolved: $TAG"; break; fi
        done
    fi
    if [ -z "$TAG" ]; then
        TAG_SOURCE=catalog
        # GitHub unreachable or no releases published. Try the console catalog
        # (public, no auth): GET ${CONSOLE_URL}/api/v1/releases/edge/current.
        # This is the R2 fallback path — assets are served via `burrowee download-url`
        # (see the dl() function below), which requires a device grant.
        info "GitHub unreachable — trying console catalog for latest edge version"
        catalog_url="${CONSOLE_URL}/api/v1/releases/edge/current"
        # Use plain curl (no TLS-only flags) when DL_BASE is set for tests, else
        # standard hardened curl.
        # shellcheck disable=SC2086  # intentional word-split of $CURL flags
        catalog_body="$($CURL "$catalog_url" 2>/dev/null)" || true
        # Resolve the tag the SAME hardened way as latest_tag(): prefer jq
        # (structural — reads only the top-level "version" field). Without jq,
        # split the body on field boundaries FIRST (tr , and { → newlines): the
        # console serves MINIFIED single-line JSON, so a line-anchored grep
        # would never match it. The field-anchored grep plus the edge/v… shape
        # check below keep a "version":"…" substring buried in notes or nested
        # metadata from spoofing the tag. (Bytes are still minisign+sha256
        # verified downstream; this closes a downgrade / wrong-version vector
        # at the resolution step.)
        if command -v jq >/dev/null 2>&1; then
            TAG="$(printf '%s' "$catalog_body" | jq -r '.version // empty' 2>/dev/null)" || true
        else
            TAG="$(printf '%s' "$catalog_body" \
                | tr ',{' '\n\n' \
                | grep -E '^[[:space:]]*"version"[[:space:]]*:' \
                | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' \
                | head -n1)" || true
        fi
        case "$TAG" in
            "$COMP"/v*) : ;;
            *) TAG="" ;;
        esac
        [ -n "$TAG" ] \
            || fail "GitHub and the console catalog are both unreachable — cannot resolve the latest edge version; retry when either is available"
        info "console catalog: $TAG"
    fi
    info "latest: $TAG"
    # A resolver that also serves the artifacts must not get to pick the version
    # too — GitHub's answer, and a mirror's answer standing in for it, are held
    # to the baked floor. See assert_version_floor.
    #
    # The console catalog is EXEMPT, deliberately. $MIN_VERSION is baked from
    # versions/<comp>.stamp — the version at CUT time — while the catalog serves
    # the last PROMOTED release, and cut and promote are separate steps that
    # legitimately lag each other. Holding the catalog to the cut floor aborts
    # every install in that window, on the only path a GitHub-blocked host has,
    # with advice ("retry when github.com is reachable") that host cannot act on.
    # The catalog is also not a third party: it is the same first-party control
    # plane the static channel and $PUBKEY come from, so exempting it costs no
    # trust this installer had not already extended. The bytes it leads to are
    # still minisign + sha256 verified and still bound to the resolved tag by the
    # signed trusted comment, so the catalog can at worst name an older release
    # OF OURS — never a forged one.
    if [ "$TAG_SOURCE" = catalog ]; then
        info "version floor not applied to the console catalog (first-party; serves the last PROMOTED release)"
    else
        assert_version_floor "$TAG"
    fi
fi
# END version-resolve

# ---- download -----------------------------------------------------------
if [ -n "$DL_BASE" ]; then
    BASE="$DL_BASE"
else
    BASE="https://github.com/${REPO}/releases/download/${TAG}"
fi
ZIP="burrowee-${COMP}-${OS}-${ARCH}.zip"
# gh-proxy mirrors route a release download by treating the release TAG as a
# SINGLE path segment. Our tags contain a slash (<comp>/v…), so a LITERAL slash
# splits the tag across two path segments and some mirror edges then fail to
# serve the asset (or return wrong bytes that later fail verification). Build a
# mirror-only base with the tag's slash percent-encoded (%2F) so the tag stays
# one segment. Direct GitHub ($BASE) keeps the literal slash (it 404s on %2F).
MIRROR_BASE="https://github.com/${REPO}/releases/download/$(printf '%s' "${TAG}" | sed 's#/#%2F#g')"

dl() {
    # dl <remote-name> <local-name>  (local goes under $TMP)
    #
    # Primary: download from $BASE (GitHub release or $BURROWEE_DL_BASE test hook).
    # Mirror fallback: if the primary fails, retry the SAME GitHub URL through each
    # GH_PROXIES HTTP mirror in turn (no auth, helps GitHub-blocked networks).
    # R2 fallback (grant gate): if all fail AND `burrowee download-url` is
    # available with a device grant, resolve a presigned URL and download from it.
    # Verification (minisign + sha256 + tag binding) is unchanged regardless of
    # download source, so neither the mirror nor R2 can inject tampered bytes or
    # substitute an older signed release undetected.
    #
    # Only the grant-gated R2 fallback relies on `burrowee` being on PATH. A plain
    # `curl install.sh | sh` with GitHub down and no `burrowee` fails with a clear
    # message — the fallback is for hosts that have already installed burrowee.
    _asset="$1"
    _local="$2"
    info "GET $BASE/$_asset"
    # Primary (GitHub) gets a tight 30s cap (the trailing --max-time overrides
    # $CURL's baked --max-time 300 — curl honours the last occurrence) so a slow or
    # throttled GitHub fails over to the mirrors fast instead of creeping for minutes.
    # The mirror attempts below keep the longer budget: they're the fallback of last
    # resort, so abandoning a working-but-slow mirror at 30s would risk failing the
    # whole install. --connect-timeout 15 + --speed-time 20 (stall) still apply.
    # shellcheck disable=SC2086  # $CURL is an intentional space-split command string (flags + binary); POSIX sh has no arrays.
    if $CURL --max-time 30 -o "$TMP/$_local" "$BASE/$_asset" 2>/dev/null; then
        return 0
    fi
    # Mirror fallback: route the %2F-encoded GitHub URL (MIRROR_BASE) through each
    # mirror in turn. Only for the real GitHub BASE (skip under the DL_BASE test
    # hook) and when enabled. Each full mirror URL is printed so a stalled download
    # is diagnosable from the installer output.
    if [ -z "$DL_BASE" ] && [ -n "$GH_PROXIES" ]; then
        for _proxy in $GH_PROXIES; do
            info "primary failed; trying mirror: $_proxy/$MIRROR_BASE/$_asset"
            # shellcheck disable=SC2086  # intentional word-split of $CURL flags
            if $CURL -o "$TMP/$_local" "$_proxy/$MIRROR_BASE/$_asset" 2>/dev/null; then
                ok "downloaded $_asset via mirror $_proxy"
                return 0
            fi
        done
    fi
    # Primary + mirrors failed. Attempt R2 fallback only when `burrowee` is on PATH.
    if command -v burrowee >/dev/null 2>&1; then
        info "primary download failed for $_asset; trying R2 fallback via burrowee"
        _r2url="$(burrowee download-url edge "$TAG" "$_asset" 2>/dev/null)" || true
        if [ -n "$_r2url" ]; then
            # Scheme guard: the resolved URL MUST be https:// in production, or
            # https:// / http:// in test mode (BURROWEE_DL_BASE set). This prevents
            # a compromised `burrowee` from redirecting to file://, ftp://, or
            # other unsafe schemes. Fail the fallback (not the whole install) if
            # the URL doesn't pass this check — user will see the no-burrowee error path.
            _valid_scheme=0
            case "$_r2url" in
                https://*)
                    _valid_scheme=1
                    ;;
                http://*)
                    # Allow http:// only in test mode (when DL_BASE is set).
                    if [ -n "$DL_BASE" ]; then
                        _valid_scheme=1
                    fi
                    ;;
            esac
            if [ "$_valid_scheme" -eq 1 ]; then
                # shellcheck disable=SC2086  # intentional word-split of $CURL flags
                $CURL -o "$TMP/$_local" "$_r2url" 2>/dev/null \
                    || fail "R2 fallback download failed for $_asset — check device grant and retry"
                ok "downloaded $_asset via R2 fallback"
                return 0
            fi
            # URL scheme invalid — treat as a fallback failure so the caller
            # sees the standard "no authorized burrowee" error.
        fi
        fail "burrowee download-url returned no URL for $_asset — device grant may be expired; run 'burrowee login' to renew, or retry when GitHub is reachable"
    fi
    fail "download failed: $_asset (from $BASE; mirrors: $GH_PROXIES) — GitHub and all mirrors are unreachable and there is no authorized burrowee on PATH — install burrowee + run 'burrowee login' to enable the backup channel, or retry when GitHub is reachable"
}
info "downloading $ZIP"
dl "$ZIP" "$ZIP"
info "downloading SHA256SUMS.txt + signature"
dl "SHA256SUMS.txt"         "SHA256SUMS.txt"
dl "SHA256SUMS.txt.minisig" "SHA256SUMS.txt.minisig"

# ---- require minisign ---------------------------------------------------
# minisign is the trust root: it must already be on PATH from a trusted source
# (your package manager). We never auto-fetch the verifier — a binary pulled
# over the network and run unverified would itself become an unverified trust
# root, defeating the whole signature chain. Verification is mandatory and is
# only ever performed by a minisign the operator already trusts.
if command -v minisign >/dev/null 2>&1; then
    MINISIGN=minisign
else
    case "$OS" in
        darwin) hint="install Homebrew if you don't have it, then minisign:
      /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"
      brew install minisign" ;;
        *)      hint="apt-get install minisign  (or your distro's package manager)" ;;
    esac
    fail "minisign is required and is not installed — install it and re-run.
    $hint
    upstream: https://github.com/jedisct1/minisign
    Verification is mandatory; this installer will NOT run an unverified verifier."
fi

# ---- VERIFY (the trust gate) --------------------------------------------
info "verifying signature"
# 1) signature over the sums file, using the baked pubkey (inline, no key fetch).
# Capture stdout — minisign prints the SIGNED "Trusted comment:" line there, and
# that comment is the only version-bearing field in the whole verified set (the
# zip name and SHA256SUMS.txt are both version-independent). stderr is left
# attached so a verification failure still shows minisign's own diagnostics.
verify_out="$("$MINISIGN" -V -P "$PUBKEY" -m "$TMP/SHA256SUMS.txt" -x "$TMP/SHA256SUMS.txt.minisig")" \
    || fail "signature verification failed — aborting (refusing to install unverified bytes)"
ok "minisign signature valid"

# 1b) BIND the verified bytes to the resolved $TAG. Signature + checksum alone
# prove the bytes are a genuine Burrowee release — NOT that they are the release
# we asked for. Any download source (notably an untrusted GH_PROXY mirror, but
# equally a stale CDN or a hostile console catalog) can answer with an OLDER,
# genuinely signed triple — zip + SHA256SUMS.txt + .minisig all mutually
# consistent — and every check above passes: a silent rollback onto a
# known-vulnerable build.
#
# This check is what makes $TAG mean something for the BYTES. It is only as
# strong as $TAG itself: when $TAG came from a pin it is the operator's own
# answer, and when it was resolved from the network it has already been held to
# $MIN_VERSION above (a resolver that also served the bytes cannot use this
# comparison to launder its own answer). The two checks are complementary and
# neither substitutes for the other.
#
# The trusted comment is covered by the signature, so it
# cannot be swapped for a different version's; releases are stamped by
# tools/release.sh / rkit as `burrowee <comp> <stamp>` where <stamp> is the tag
# minus its "<comp>/" prefix. Mismatch (or a release predating the stamp
# convention) fails closed.
trusted="$(printf '%s\n' "$verify_out" | sed -n 's/^Trusted comment: //p')"
expect="burrowee $COMP ${TAG#*/}"
[ "$trusted" = "$expect" ] || fail "version binding failed — the signed release is \"$trusted\" but \"$expect\" was requested.
    Refusing to install: this is what a rollback to an older signed release looks like.
    Retry (a mirror may be serving a stale release), or pin the version you want
    and install again."
ok "version binding verified ($TAG)"

info "verifying checksum"
# 2) the zip's checksum against the now-trusted sums file
grep -qF "$ZIP" "$TMP/SHA256SUMS.txt" \
    || fail "no checksum entry for $ZIP — release incomplete or tampered; aborting"
if command -v shasum >/dev/null 2>&1; then
    ( cd "$TMP" && shasum -a 256 -c --ignore-missing SHA256SUMS.txt >/dev/null ) \
        || fail "checksum mismatch — aborting (zip tampered or download corrupted)"
elif command -v sha256sum >/dev/null 2>&1; then
    ( cd "$TMP" && sha256sum -c --ignore-missing SHA256SUMS.txt >/dev/null ) \
        || fail "checksum mismatch — aborting (zip tampered or download corrupted)"
else
    fail "neither shasum nor sha256sum found — cannot verify; aborting"
fi
ok "checksum verified"

# ---- unzip + exec the verified inner installer --------------------------
command -v unzip >/dev/null 2>&1 \
    || fail "unzip not found — install it (\`brew install unzip\` / \`apt-get install unzip\`) and retry"
unzip -q -o "$TMP/$ZIP" -d "$TMP/x" || fail "zip extraction failed — corrupt download?"
[ -f "$TMP/x/install.sh" ] || fail "release zip missing inner install.sh — aborting"

ok "verified — running inner installer"
# Run with cwd = the unzipped dir: the inner installer resolves the binaries
# relative to its own location (./burrowee, ./burrowee-cli, …).
( cd "$TMP/x" && PREFIX="$PREFIX" BURROWEE_UNINSTALL="${BURROWEE_UNINSTALL:-}" BURROWEE_VERSION="$TAG" sh ./install.sh )

# ---- PATH persistence ---------------------------------------------------
# On a real install, idempotently add PREFIX/bin to the operator's shell rc so a
# fresh shell finds `burrowee` (the live-VPS `command not found`). bash reads
# ~/.bashrc for INTERACTIVE shells, but a LOGIN shell (ssh) reads the first of
# ~/.bash_profile / ~/.bash_login / ~/.profile and does NOT auto-source ~/.bashrc
# — so write to both the interactive rc and the login file, else PATH is missing
# over ssh. An unset/unknown $SHELL defaults to the bash files. Fault-tolerant:
# an unwritable rc must never abort the script (the bins are already installed).
# Skipped as root: a root install lands in /usr/local/bin (already on PATH), so
# appending a $PREFIX/bin marker to root's rc would be wrong and useless.
if [ -z "${BURROWEE_UNINSTALL:-}" ] && [ -z "${BURROWEE_NO_PATH_EDIT:-}" ] && [ "$(id -u)" != 0 ]; then
    BIN_DIR="$PREFIX/bin"
    case ":$PATH:" in
        *":$BIN_DIR:"*) : ;;   # already on PATH this shell
        *)
            # rc set: interactive rc + the login file the shell actually sources.
            case "$(basename "${SHELL:-bash}")" in
                zsh)
                    rc_files="$HOME/.zshrc"
                    [ -f "$HOME/.zprofile" ] && rc_files="$rc_files $HOME/.zprofile"
                    ;;
                *)  # bash (and any unrecognized shell defaults to bash rc files)
                    rc_files="$HOME/.bashrc"
                    if   [ -f "$HOME/.bash_profile" ]; then rc_files="$rc_files $HOME/.bash_profile"
                    elif [ -f "$HOME/.bash_login" ];   then rc_files="$rc_files $HOME/.bash_login"
                    else rc_files="$rc_files $HOME/.profile"; fi
                    ;;
            esac
            for rc in $rc_files; do
                if [ -f "$rc" ] && grep -q 'burrowee PATH' "$rc" 2>/dev/null; then
                    continue   # marker already present in this file
                fi
                {
                    printf '\n# >>> burrowee PATH >>>\n'
                    printf 'export PATH="%s:$PATH"\n' "$BIN_DIR"
                    printf '# <<< burrowee PATH <<<\n'
                } >> "$rc" 2>/dev/null && info "added $BIN_DIR to PATH in $rc"
            done
            info "run: export PATH=\"$BIN_DIR:\$PATH\"   (or open a new shell) to use burrowee now"
            ;;
    esac
fi

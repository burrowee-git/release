#!/bin/sh
# Burrowee outer bootstrap — THE TRUST ANCHOR (POSIX sh, macOS + Linux).
#
#   curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/cli/install.sh | sh
#   curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/cli/upgrade.sh | sh -s -- 0.2.0
#   curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/cli/updater.install.sh | sh   (edge/gateway only)
#
# This is the stable, curl'd-alone entry point for the `cli` component
# (which bundles the `burrowee` dispatcher). It NEVER runs an unverified byte:
# it downloads the release zip + SHA256SUMS.txt + its minisig, verifies the
# minisign signature with a baked-in PUBLIC key, verifies the zip's sha256
# against the now-trusted sums file, and ONLY THEN unzips and execs the inner
# script the baked mode names. Any failure aborts before anything is installed.
#
# THREE MODES, ONE TEMPLATE. install is substituted at render time and decides
# which inner script this file hands off to once the release is verified:
#
#   install.sh          resolve + verify + unzip  →  ./install.sh
#   upgrade.sh           resolve + verify + unzip  →  ./install.sh  →  ./migrations/upgrade.sh <floor>
#   updater.install.sh  resolve + verify + unzip  →  ./updater.install.sh
#
# install.sh and upgrade.sh place (or update) the WHOLE component. updater.install.sh
# is the narrow RECOVERY path: it reinstalls ONLY the updater (binary + unit) on
# a host that already has the component, for when the updater itself is stale,
# stopped, or was never installed — the one situation the updater cannot fix by
# shipping itself an update, because the thing that would fetch it is the thing
# that is broken. It is rendered for edge and gateway ONLY
# (tools/gen-bootstraps.sh's UPDATER_INSTALL_COMPONENTS): those are the two
# components with a supervised updater SERVICE to recover — cli's updater is a
# one-shot binary with no service, and agent has no updater installer either.
#
# The composition lives HERE, one layer above every inner script, so none of
# them grows a second job: install.sh is still the only thing that places
# binaries, migrations/upgrade.sh is still migrations-only, and
# updater.install.sh still touches only the updater. And it is the SAME FILE,
# not a fork per mode: everything that makes this script a trust anchor — the
# pinned preflight sha256, the baked pubkey, the v0.2.5.2026.08.25.2d1503e6 floor, the
# SHA256SUMS.txt minisign gate — is the same lines for all three modes, because
# a copy of a trust anchor is a copy that drifts from it.
#
# WHY upgrade.sh EXISTS AT ALL, given install.sh already runs the ladder gated:
# the ladder's gate compares only MAJOR.MINOR.PATCH and deliberately ignores the
# .date.sha tail, so a host that changed BUILD without changing SEMVER —
# 0.2.0.2026.08.08.79a5cfd7 → 0.2.0.2026.08.17.4e43c2ed — is invisible to it and
# looks already migrated. upgrade.sh is the one-liner for that case.
#
# install.sh AND upgrade.sh ARE RENDERED FOR EVERY PUBLIC COMPONENT, not only
# for those shipping a ladder today. Which kits carry migrations/ is decided in
# the COMPONENT repos at their cut; this repo renders a static file at ITS cut
# and serves it from a URL we advertise. A conditional render would put a "does
# cli have a ladder" belief in this repo that nothing keeps in step with the
# zips, and the first time it was wrong the URL would 404. So the file always
# exists, and a kit with no migrations/upgrade.sh is a RUNTIME refusal naming
# the component and the version just installed — a message an operator can act
# on. updater.install.sh is different: it is NOT rendered for every public
# component, because "has a supervised updater service" is a fixed fact about
# the component itself, decided at design time — not about what a release zip
# happens to ship this cut.
#
# DO NOT EDIT generated copies (cli/install.sh, cli/upgrade.sh, and for
# edge/gateway cli/updater.install.sh) by hand — they are produced from
# tools/bootstrap.template.sh by tools/gen-bootstraps.sh.
#
# Arguments (upgrade.sh only; install.sh takes none and REJECTS any):
#   <floor>                      the migration floor, e.g. 0.2.0 — an INCLUSIVE
#                                floor meaning "assume this host is below it":
#                                after the install, every migration the kit
#                                carries targeting <floor> or newer is forced,
#                                receipts reopened; older targets are treated as
#                                done. It never changes WHICH release installs —
#                                that is always the newest the channel serves
#                                (or the BURROWEE_<COMP>_VERSION pin). Optional:
#                                absent, the floor defaults to the newest target
#                                in the installed kit's own ladder — the whole
#                                shipped ladder, and never a value derived from
#                                the release tag, which would refuse on every
#                                release that ships no new rung. The kit itself
#                                refuses a floor above its ladder top (64).
#
# Exit codes (upgrade.sh):
#   0   installed; the ladder applied nothing (its 0) or its rungs RAN (its 2)
#   1   installed, but the ladder refused or failed (its 1) — or any other abort
#   3   installed, the ladder ran, but a receipt was lost (its 3) — re-runnable
#  64   the command line was wrong, or the ladder rejected the one built for it
#
# Env vars:
#   BURROWEE_<COMP>_VERSION      pin a release tag (e.g. cli/v0.1.0.…); default: latest
#                                (<COMP> = the component name upper-cased, e.g. BURROWEE_CLI_VERSION)
#   PREFIX                       install root (bins at PREFIX/bin). cli/agent: default
#                                $HOME/.local. GATEWAY and EDGE: not defaulted — they
#                                install only to the root-owned /usr/local/bin (gateway
#                                since 0.2.0, edge since 0.2.0). Their inner installers
#                                REFUSE a PREFIX that would MISDIRECT the install rather
#                                than quietly overriding it; one that resolves to that
#                                same /usr/local/bin misdirects nothing and is honoured.
#   (elevation)                  gateway/edge/relay need root: the bootstrap runs the
#                                VERIFIED inner installer under sudo and says so.
#                                Resolution, download and signature checks stay at the
#                                invoking user. No tty + no cached creds, or no sudo at
#                                all, is a refusal before anything is placed.
#   BURROWEE_UNINSTALL=1         pass through to the inner installer to remove bins
#   BURROWEE_RELEASE_REPO        GitHub repo serving releases (default burrowee-git/release)
#   BURROWEE_SKIP_PREFLIGHT=1    skip the OS-dependency preflight (manage deps yourself)
#   BURROWEE_SKIP_NGINX=1        (edge) skip nginx + stream module in the preflight
#   BURROWEE_NO_PATH_EDIT=1      do not persist PREFIX/bin to your shell rc (no effect for
#                                the gateway or the edge, which edit no rc —
#                                /usr/local/bin is on PATH already)
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
COMP="cli"
# "install" or "upgrade" — see the two-modes note in the header. Baked, never
# read from the environment: the mode is a property of the URL the operator
# curl'd, and a runtime override would make one file behave as the other.
MODE="install"
PUBKEY="RWT/O8xU4IbIBI1rg1T9ddsPLqdhI7wOYaVPDt/9ctT2TkNI2H2yLXFk"
PREFLIGHT_SHA256="d6382a0ad2a38630cfcd39b105cafac48b615a514aa6644352f85b075ade2cd9"
# The version floor: the stamp this component was at when THIS installer was
# generated and published (baked from versions/<comp>.stamp by
# tools/gen-bootstraps.sh, which release.sh re-runs on every cut). A tag
# resolved from GitHub — or from a GH_PROXY mirror standing in for it — must be
# at least this version; see "version floor" below (the first-party console
# catalog is exempt, for the reason spelled out at the resolution choke point).
# It rides the same first-party static channel, over the same TLS fetch, that
# delivered $PUBKEY, so it costs no trust the installer did not already require;
# and no download source gets to choose it.
MIN_VERSION="v0.2.5.2026.08.25.2d1503e6"
REPO="${BURROWEE_RELEASE_REPO:-burrowee-git/release}"

# resolve_prefix — the install root this bootstrap hands the inner installer.
#
# PER COMPONENT, because this template is shared and they no longer agree. The
# gateway and the edge install to /usr/local/bin, root-owned, and nowhere else:
# their inner installers REFUSE a PREFIX that names anywhere else, so
# manufacturing a per-user one here would make every `curl … | sh` fail — and,
# before that refusal existed, manufacturing one is precisely what sent every
# bootstrap install down the per-user branch, which also switched off unit
# rendering, migration and version recording. Their PREFIX therefore stays EMPTY
# unless the operator set one, and an operator who did set one gets either the
# refusal they earned or, if it resolves to /usr/local/bin anyway, a line saying
# so — never a silent override. cli/agent keep the per-user default until that
# is decided separately. $COMP is a literal baked at render time.
#
# WHAT IT EXPORTS IS CANONICAL: repeated slashes collapsed, trailing ones
# stripped (empty stays empty — it is the "operator set nothing" signal below,
# not a path). The root-only installers' gate normalises before comparing, so it
# accepts `PREFIX=/usr/local/` as naming its own destination — and everything
# DOWNSTREAM of that acceptance does plain string work: the migration runner
# derives BIN_DIR="${BIN_DIR:-${PREFIX:-/usr/local}/bin}" and the stale-bin sweep
# decides "never sweep the install destination" by comparing directory names as
# TEXT. `/usr/local//bin` opens the same directory and matches none of those
# names. Collapsing here means one spelling leaves this bootstrap, whatever the
# operator typed.
resolve_prefix() {
    case "$COMP" in
        gateway | edge) _rp="${PREFIX:-}" ;;
        *)              _rp="${PREFIX:-$HOME/.local}" ;;
    esac
    [ -n "$_rp" ] || return 0
    # The same two substitutions the inner installers' normalize_dir applies,
    # spelled the same way on purpose — this is the value that gate compares.
    # printf, never echo: echo expands backslash escapes in dash and in macOS
    # /bin/sh, so a PREFIX carrying one would be silently rewritten here.
    _rp="$(printf '%s' "$_rp" | sed -e 's|//*|/|g' -e 's|/*$||')"
    printf '%s' "${_rp:-/}"
}
PREFIX="$(resolve_prefix)"
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
# BEGIN helpers
fail() { printf '\n  ✗ %s\n\n' "$*" >&2; exit 1; }
info() { printf '  → %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
# END helpers

# ---- elevation ----------------------------------------------------------
# THE POLICY: a root-only surface never dead-ends. gateway, edge and relay
# install to /usr/local/bin and manage a system service; they cannot install any
# other way. So the bootstrap elevates rather than printing a one-liner for the
# operator to retype.
#
# WHERE, and why it is here and not at the top: everything above this point --
# resolving the tag, downloading, minisign, sha256, the preflight -- runs at the
# OPERATOR's uid. Root executes only bytes already proven to be the signed
# release. Elevating at the top would run the whole network-facing chain as root
# for no gain, and would put the preflight's brew path (Homebrew refuses to run
# as root) on the wrong side of the boundary. Do not reorder this.
needs_root_comp() {
    case "$COMP" in
        gateway | edge) return 0 ;;
        *)              return 1 ;;
    esac
}

# ELEVATE_HINT -- the exact re-run command the pinned refusal below shows when
# this run has no tty and no cached sudo credentials. Lives HERE, beside
# needs_root_comp(), because it differs the same way and for the same reason:
# gateway/edge take no secret on the command line, so the plain piped re-run
# under sudo works verbatim. relay's own copy of this variable
# (tools/relay-bootstrap.template.sh) says something else, because relay's
# operator key cannot survive the sudo boundary -- see that file's comment.
ELEVATE_HINT="curl -fsSL --proto '=https' --tlsv1.2 $CHANNEL_BASE/$MODE.sh | sudo sh"

# ---- BEGIN pinned elevation literals -------------------------------------
# Kept byte-identical between tools/bootstrap.template.sh and
# tools/relay-bootstrap.template.sh — tools/test-elevate.sh assertion (9)
# diffs everything between these two markers. needs_root_comp() above is
# deliberately OUTSIDE the pinned range: it differs by design (the shared
# template switches on $COMP; relay is root-only unconditionally).
# has_tty -- copied VERBATIM from inner/gateway/install.sh, which already solves
# the piped case: under `curl … | sh` stdin IS the script, so `[ -t 0 ]` is
# false, and the /dev/tty probe is the only thing that finds the terminal.
has_tty() {
    [ -t 0 ] && return 0
    ( exec </dev/tty ) 2>/dev/null
}

# resolve_elevate -- prints `sudo`, or nothing. Refuses (exit 1) rather than
# proceeding toward an install that cannot finish.
resolve_elevate() {
    needs_root_comp || return 0
    [ "$(id -u)" != 0 ] || return 0
    if ! command -v sudo >/dev/null 2>&1; then
        fail "$COMP installs to /usr/local/bin and manages a system service, so it needs root — and sudo is not installed on this host. Re-run this installer as root."
    fi
    if ! has_tty && ! sudo -n true 2>/dev/null; then
        fail "$COMP needs root to install, and this run has no terminal for a sudo password prompt and no cached sudo credentials. Re-run it from an interactive terminal, pre-authorize with \`sudo -v\`, or run:
    $ELEVATE_HINT"
    fi
    printf 'sudo'
}
ELEVATE="$(resolve_elevate)"
# ---- END pinned elevation literals ---------------------------------------

# BEGIN sha256
# sha256 of a file, as a bare hex digest. shasum on macOS, sha256sum on stock
# Debian/Ubuntu (which ships no perl and therefore no shasum). Both spellings
# are pre-2016-safe: no --ignore-missing, no --check.
sha256_of() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else return 1; fi
}
# END sha256

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
# stale tag. Note that returning 0 with NO output is a different answer — the
# source was reached and has nothing matching — and the caller distinguishes the
# two, because "unreachable" and "no such line" want different advice.
#
# The upgrade argument does NOT filter this resolution. It is the migration
# FLOOR, handed to the verified kit's own forcing entry after the install — the
# resolution always takes the newest release the channel serves (or the
# BURROWEE_<COMP>_VERSION env pin). A resolution-pinning argument was tried and
# retired: it coupled "which release installs" to "which migrations force", and
# the version floor baked into this file made any line behind the current cut
# unreachable anyway — the one lever it added was already refused.
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
# BEGIN platform-detect
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
# END platform-detect

# ---- guard against a TEMP / unbaked pubkey ------------------------------
# BEGIN pubkey-guard
case "$PUBKEY" in
    ""|*REPLACE*|*PLACEHOLDER*|*TEMP*)
        fail "this installer was built without a real signing key — refusing to verify against a placeholder (regenerate with tools/gen-bootstraps.sh)" ;;
esac
# END pubkey-guard

# BEGIN mode-dispatch  (cmd/rkit's updater-install bootstrap test extracts this
# block verbatim and drives it directly — keep it self-contained between the
# markers, and keep the markers.)
# ---- guard against an unbaked mode, and resolve which inner script runs ----
# Fails closed for the same reason the pubkey guard does: an unsubstituted
# install would fall through every mode check below, so a bootstrap rendered by a
# broken generator would install and then silently skip a step it exists for —
# or, worse, run the WRONG inner script — instead of refusing outright.
#
# INNER is the one thing $MODE ultimately controls that changes what gets
# EXECUTED. install and upgrade both hand off to the full component installer
# (./install.sh — upgrade additionally forces migrations afterward, further
# down); updater.install hands off to the narrow recovery script
# (./updater.install.sh) instead. Nothing about resolve, download, minisign or
# sha256 differs by mode — those all run identically above this point,
# regardless of which inner script INNER ends up naming.
case "$MODE" in
    install|upgrade) INNER="install.sh" ;;
    updater.install)  INNER="updater.install.sh" ;;
    *) fail "this bootstrap was generated without a mode (got \"$MODE\") — regenerate with tools/gen-bootstraps.sh" ;;
esac
# END mode-dispatch

# BEGIN mode-args
# ---- the command line ---------------------------------------------------
# EVALUATED BEFORE THE NETWORK IS TOUCHED. A refusal that arrives after the
# preflight has installed packages and the resolver has walked GitHub is a
# refusal that already changed the host.
#
# install.sh takes NO arguments and rejects them rather than discarding them: a
# verb that silently drops what it was given is what a mistyped subcommand
# becomes, and `| sh -s -- 0.2.0` against install.sh is exactly that mistype.
#
# upgrade.sh takes at most one — the migration FLOOR. It is optional (absent,
# the installed kit's own newest ladder target is used, i.e. the whole shipped
# ladder) and it never changes which release installs: see the forced-migration
# block for the floor's meaning.
usage() {
    printf 'usage: curl -fsSL https://release.burrowee.com/%s/%s.sh | sh' "$COMP" "$MODE"
    case "$MODE" in
        upgrade)
            printf ' -s -- [<floor>]\n\n'
            printf 'Install the newest %s release and then FORCE its state migrations from the\n' "$COMP"
            printf 'same verified kit. <floor> is an INCLUSIVE floor, MAJOR.MINOR.PATCH (e.g. 0.2.0;\n'
            printf 'a leading "v" and a release stamp'"'"'s trailing .date.sha are accepted): rungs\n'
            printf 'targeting it or newer are forced, older targets are treated as done. Omitted,\n'
            printf 'the kit'"'"'s whole shipped ladder is forced. The floor never changes which release\n'
            printf 'installs — pin that with the BURROWEE_<COMP>_VERSION environment variable.\n\n'
            printf 'exit: 0 installed (ladder applied nothing, or its rungs ran) · 1 the ladder\n'
            printf 'refused or failed · 3 the ladder ran but a receipt was lost · 64 bad command line.\n'
            ;;
        updater.install)
            printf '\n\nReinstall ONLY the %s updater (binary + unit) on a host that already has\n' "$COMP"
            printf '%s installed. This is the RECOVERY path for when the updater itself is stale,\n' "$COMP"
            printf 'stopped, or was never installed — it never touches %s'"'"'s serve binary or its\n' "$COMP"
            printf 'enrollment/config state. Takes no arguments. To install %s itself, use\n' "$COMP"
            printf 'install.sh instead.\n'
            ;;
        *)
            printf '\n\nInstall the latest %s release. Takes no arguments; pin a specific release with\n' "$COMP"
            printf 'the BURROWEE_<COMP>_VERSION environment variable. To force the kit'"'"'s state\n'
            printf 'migrations as well, use upgrade.sh instead.\n'
            ;;
    esac
}

# usage_error — stderr and 64 (EX_USAGE). 64 rather than 1 so a typo can never
# be read as "the ladder refused", and rather than 0 so a script does not pass
# on a mistyped argument. It is the same code migrations/run.sh and
# migrations/upgrade.sh use for the same thing.
usage_error() {
    printf '\n  \342\234\227 %s\n\n' "$1" >&2
    usage >&2
    exit 64
}

# norm_line <string> — MAJOR.MINOR.PATCH, or non-zero when the value is not
# something that may be compared as a version. This is what normalizes the
# operator's migration FLOOR before it is handed to the kit. Deliberately the
# same SHAPE as migrations/upgrade.sh's norm_version and run.sh's
# valid_version, and for the same reason: a non-numeric field reads as 0 in the
# ladder's gate, so "0.2.x" would quietly become 0.2.0 and select some other
# line's rungs. It is marginally STRICTER than those two — it rejects a
# `-rc1` / `+meta` suffix outright rather than trimming it — which only moves a
# refusal the ladder would have made anyway to before the network is touched.
norm_line() {
    _nl="${1##*/}"
    _nl="${_nl#v}"
    case "$_nl" in
        *.*.*) ;;
        *) return 1 ;;
    esac
    _nl_major="${_nl%%.*}"
    _nl_rest="${_nl#*.}"
    _nl_minor="${_nl_rest%%.*}"
    _nl_rest="${_nl_rest#*.}"
    _nl_patch="${_nl_rest%%.*}"
    for _nl_f in "$_nl_major" "$_nl_minor" "$_nl_patch"; do
        case "$_nl_f" in
            ''|*[!0-9]*) return 1 ;;
        esac
    done
    printf '%s.%s.%s' "$_nl_major" "$_nl_minor" "$_nl_patch"
}

FLOOR=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help|help)
            usage
            exit 0 ;;
        -*)
            usage_error "unknown option '$1'" ;;
        *)
            case "$MODE" in
                upgrade) : ;;
                install) usage_error "$COMP/install.sh takes no arguments, and was given '$1' — did you mean upgrade.sh, which takes the migration floor?" ;;
                *)       usage_error "$COMP/$MODE.sh takes no arguments, and was given '$1'" ;;
            esac
            [ -z "$FLOOR" ] \
                || usage_error "unexpected extra argument '$1' — upgrade.sh takes at most one, the migration floor"
            FLOOR="$(norm_line "$1")" \
                || usage_error "'$1' is not a version this bootstrap can compare — expected MAJOR.MINOR.PATCH, all numeric (0.2.0, v0.2.0, or the stamp 0.2.0.2026.08.17.4e43c2ed)"
            shift ;;
    esac
done
# END mode-args

# ---- temp workspace -----------------------------------------------------
# BEGIN tmp-workspace
TMP="$(mktemp -d "${TMPDIR:-/tmp}/burrowee-${COMP}-XXXXXX")" || fail "could not create temp dir"
trap 'rm -rf "$TMP"' EXIT INT TERM
# END tmp-workspace

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
    # GH_ANSWERED separates "nobody could be reached" from "the source was
    # reached and answered empty" — the two want different advice.
    GH_ANSWERED=0
    if TAG="$(resolve_latest '')"; then GH_ANSWERED=1; else TAG=""; fi
    # GitHub API unreachable/empty — retry through each mirror in turn BEFORE the
    # console catalog (mirrors need no authorized burrowee, so they serve fresh
    # hosts). Skipped under the DL_BASE test hook and when mirrors are disabled.
    if [ -z "$TAG" ] && [ -z "$DL_BASE" ] && [ -n "$GH_PROXIES" ]; then
        for _proxy in $GH_PROXIES; do
            info "GitHub API unreachable — retrying via mirror $_proxy"
            if TAG="$(resolve_latest "$_proxy/")"; then GH_ANSWERED=1; else TAG=""; fi
            if [ -n "$TAG" ]; then info "mirror resolved: $TAG"; break; fi
        done
    fi
    if [ -z "$TAG" ]; then
        TAG_SOURCE=catalog
        # GitHub unreachable or no releases published. Try the console catalog
        # (public, no auth): GET ${CONSOLE_URL}/api/v1/releases/cli/current.
        # This is the R2 fallback path — assets are served via `burrowee download-url`
        # (see the dl() function below), which requires a device grant.
        info "GitHub unreachable — trying console catalog for latest cli version"
        catalog_url="${CONSOLE_URL}/api/v1/releases/cli/current"
        # Use plain curl (no TLS-only flags) when DL_BASE is set for tests, else
        # standard hardened curl.
        # shellcheck disable=SC2086  # intentional word-split of $CURL flags
        catalog_body="$($CURL "$catalog_url" 2>/dev/null)" || true
        # Resolve the tag the SAME hardened way as latest_tag(): prefer jq
        # (structural — reads only the top-level "version" field). Without jq,
        # split the body on field boundaries FIRST (tr , and { → newlines): the
        # console serves MINIFIED single-line JSON, so a line-anchored grep
        # would never match it. The field-anchored grep plus the cli/v… shape
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
            || fail "GitHub and the console catalog are both unreachable — cannot resolve the latest cli version; retry when either is available"
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
        _r2url="$(burrowee download-url cli "$TAG" "$_asset" 2>/dev/null)" || true
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
# BEGIN verify-checksum
# v4: declares needs: helpers too — the block below calls fail(), which lives
# in the helpers module, not sha256. Under-declaring it was latent only because
# every current template happens to splice helpers before this module.
# Compare ONE hash directly instead of `-c --ignore-missing` over the whole
# sums file: --ignore-missing is a 2016-era addition (Digest::SHA 5.96 /
# coreutils 8.25) and the stock shasum on an older macOS rejects it outright
# ("Unknown option: ignore-missing"). That non-zero exit came back through the
# `||` as "checksum mismatch", so every install on such a host accused a
# perfectly good zip of tampering. Picking the line by EXACT filename (awk, both
# the "hash  name" and binary "hash *name" spellings) is also stricter than the
# substring grep this replaces.
want="$(awk -v f="$ZIP" '{ n = $2; sub(/^\*/, "", n); if (n == f) { print $1; exit } }' "$TMP/SHA256SUMS.txt")"
[ -n "$want" ] \
    || fail "no checksum entry for $ZIP — release incomplete or tampered; aborting"
got="$(sha256_of "$TMP/$ZIP")" \
    || fail "neither shasum nor sha256sum found — cannot verify; aborting"
[ -n "$got" ] && [ "$want" = "$got" ] \
    || fail "checksum mismatch — aborting (zip tampered or download corrupted)"
# END verify-checksum
ok "checksum verified"

# ---- unzip + exec the verified inner installer --------------------------
command -v unzip >/dev/null 2>&1 \
    || fail "unzip not found — install it (\`brew install unzip\` / \`apt-get install unzip\`) and retry"
unzip -q -o "$TMP/$ZIP" -d "$TMP/x" || fail "zip extraction failed — corrupt download?"
[ -f "$TMP/x/$INNER" ] || fail "release zip missing inner $INNER — aborting"

ok "verified — running inner $INNER"
# run_inner — exec the verified inner installer with cwd = the unzipped dir, so
# it resolves the binaries relative to its own location (./burrowee,
# ./burrowee-cli, …).
#
# PREFIX is exported only when it has a value. The difference between "unset"
# and "set to empty" is load-bearing for the gateway and the edge: their
# installers branch on `[ -n "${PREFIX:-}" ]` to refuse a per-user install, and
# passing an empty PREFIX would read as an operator who set nothing — which is
# right — while passing a defaulted one would refuse every ordinary install.
# cli/agent always have a value here, so nothing changes for them.
run_inner() {
    # Every variable crossing the boundary is spelled as a command-prefix
    # assignment on the `sh` invocation, NOT exported: sudo scrubs the
    # environment, and PREFIX's empty-vs-unset distinction is load-bearing for
    # the gateway and edge root-only gates. An exported PREFIX would arrive
    # unset and read as "the operator set nothing", turning a deliberate
    # PREFIX=/usr/local into a silent default.
    if [ -n "$ELEVATE" ]; then
        info "$COMP installs to /usr/local/bin and manages a system service — elevating with sudo for the install step (the download and its signature check already ran as $(id -un))"
    fi
    if [ -n "$PREFIX" ]; then
        ( cd "$TMP/x" && $ELEVATE env PREFIX="$PREFIX" \
            BURROWEE_UNINSTALL="${BURROWEE_UNINSTALL:-}" \
            BURROWEE_NO_UPDATER="${BURROWEE_NO_UPDATER:-}" \
            BURROWEE_FORCE_SERVICE_OVERRIDE="${BURROWEE_FORCE_SERVICE_OVERRIDE:-}" \
            BURROWEE_NO_RESTART="${BURROWEE_NO_RESTART:-}" \
            BURROWEE_VERSION="$TAG" sh "./$INNER" )
    else
        ( cd "$TMP/x" && $ELEVATE env \
            BURROWEE_UNINSTALL="${BURROWEE_UNINSTALL:-}" \
            BURROWEE_NO_UPDATER="${BURROWEE_NO_UPDATER:-}" \
            BURROWEE_FORCE_SERVICE_OVERRIDE="${BURROWEE_FORCE_SERVICE_OVERRIDE:-}" \
            BURROWEE_NO_RESTART="${BURROWEE_NO_RESTART:-}" \
            BURROWEE_VERSION="$TAG" sh "./$INNER" )
    fi
}
run_inner

# ---- upgrade mode: the forced migration pass ----------------------------
# THE SECOND STEP, and the only thing that separates upgrade.sh from install.sh.
# It runs out of $TMP/x — the SAME verified kit the installer just ran from — so
# the migrations that execute are the ones signed alongside the binaries that
# were just placed, not whatever an earlier install left on disk.
#
# ORDER IS LOAD-BEARING and is enforced by `set -e`, not by a comment: run_inner
# above aborts the script on a non-zero inner installer, so the ladder cannot
# run against a host whose binaries did not land.
#
# THE FLOOR IS THE OPERATOR'S ARGUMENT, VERBATIM — and when none was given, it
# is derived from the KIT'S OWN LEDGER (its newest target), NEVER from the
# release tag. A tag-derived default assumes *ladder top == release line*,
# which holds only for releases that ship a new rung: the first release whose
# line moved past an unchanged ladder (0.2.1 over a 0.2.0-topped ladder) made
# every tag-derived run refuse after a successful install. The ledger is read
# out of $TMP/x — the same verified kit the migrations will run from — so the
# default the bootstrap names and the ladder the kit judges it against cannot
# be two different beliefs. The kit's own cross-check stays the judge of an
# operator-named floor (it refuses one above its ladder top).
if [ "$MODE" = upgrade ]; then
    # A kit with no ladder SAYS SO AND FAILS. Silent success here is the defect
    # this month keeps producing: a zip shipped without migrations/, an update
    # that skipped its state migration, and nothing in the output to show it.
    # The component and the version just installed are both named, because the
    # operator's next question is which of the two is wrong.
    #
    # *** THIS CHECK IS LOAD-BEARING, NOT BELT AND BRACES. *** `sh <script>`
    # exits 2 when it cannot open the script (dash, and /bin/sh on Debian and
    # Ubuntu) — the SAME 2 the ladder uses for "rungs ran, success". So a
    # missing, unreadable or empty migrations/upgrade.sh invoked without this
    # guard is not merely reported badly, it is reported as a COMPLETED
    # MIGRATION. Nothing downstream can tell the two apart: by the time the code
    # is read, the only evidence of which one happened is gone. These per-file
    # tests are cheap and they are the whole defence — removing any of them is
    # removing the reason exit 2 can be trusted at all. run.sh and the ledger
    # get the same treatment: the runner because the forcing entry execs it,
    # the ledger because the default floor is read out of it below.
    for _kit_f in migrations/upgrade.sh migrations/run.sh migrations/ledger; do
        { [ -f "$TMP/x/$_kit_f" ] && [ -r "$TMP/x/$_kit_f" ] && [ -s "$TMP/x/$_kit_f" ]; } \
            || fail "$COMP $TAG ships no usable $_kit_f — this release has no migration ladder, so there is nothing for upgrade.sh to force.
    The ${COMP} binaries from $TAG ARE installed: this run placed them, and only
    the migration half had nothing to run. If ${COMP} is not expected to have a
    ladder, the plain installer is the right entry point:
      curl -fsSL --proto '=https' --tlsv1.2 https://release.burrowee.com/$COMP/install.sh | sh"
    done

    if [ -n "$FLOOR" ]; then
        MIG_FLOOR="$FLOOR"
        info "migration floor $MIG_FLOOR (your argument): rungs targeting it or newer will be forced"
    else
        # The kit ledger's NEWEST target, by numeric comparison on the first
        # three fields — the same computation migrations/upgrade.sh makes, so
        # the default this bootstrap names is one the kit accepts by
        # construction. Never the last row: rows may share a target, and ledger
        # order is the runner's contract, not this script's to assume.
        MIG_FLOOR="$(awk '
            function vf(v, i,   a, n, f) {
                n = split(v, a, "."); if (i > n) return 0
                f = a[i]; sub(/[-+].*/, "", f)
                if (f !~ /^[0-9]+$/) return 0
                return f + 0
            }
            function newer(a, b,   i, x, y) {
                for (i = 1; i <= 3; i++) {
                    x = vf(a, i); y = vf(b, i)
                    if (x > y) return 1
                    if (x < y) return 0
                }
                return 0
            }
            { sub(/#.*$/, ""); for (i = 1; i <= NF; i++) word[++c] = $i }
            END {
                if (c == 0 || c % 2 != 0) exit 1
                top = word[1]
                for (i = 3; i <= c; i += 2) if (newer(word[i], top)) top = word[i]
                sub(/^.*\//, "", top); sub(/^v/, "", top)
                print top
            }
        ' "$TMP/x/migrations/ledger")" \
            || fail "$COMP $TAG ships a migration ledger this bootstrap cannot read — refusing to guess a floor for it. The ${COMP} binaries from $TAG ARE installed; only the forced migration pass did not run."
        [ -n "$MIG_FLOOR" ] \
            || fail "$COMP $TAG ships a migration ledger this bootstrap cannot read — refusing to guess a floor for it. The ${COMP} binaries from $TAG ARE installed; only the forced migration pass did not run."
        info "migration floor $MIG_FLOOR (this kit's newest ladder target): the whole shipped ladder will be forced"
    fi

    info "forcing the state migrations from floor $MIG_FLOOR up, from the verified kit"
    # `set +e` around the call ONLY. The ladder's non-zero codes are its
    # contract, not a failure of this script, and `set -e` would abort here and
    # throw away the code the mapping below exists to read. Not a pipeline: `$?`
    # after a pipe is the LAST command's status, which is how an exit-mapping
    # test ends up reporting on something it never measured.
    set +e
    ( cd "$TMP/x" && $ELEVATE sh ./migrations/upgrade.sh "$MIG_FLOOR" )
    LADDER=$?
    set -e

    # THE MAPPING, stated explicitly and printed. The ladder's contract is five
    # values and TWO of them are success: 0 (nothing applied) and 2 (rungs RAN).
    # A bootstrap that treated non-zero as failure would report every real
    # upgrade as broken; one that ignored the code would report a refusal as
    # success. 3 and 64 are passed through as themselves rather than folded into
    # 1, because they mean different things to whoever is reading `echo $?`.
    case "$LADDER" in
        0)  MAPPED=0; LADDER_MEANING="nothing applied — this host needed no migration" ;;
        2)  MAPPED=0; LADDER_MEANING="migrations RAN (success) — $COMP is STOPPED and starting it is yours" ;;
        3)  MAPPED=3; LADDER_MEANING="migrations ran but a receipt was lost — $COMP is STOPPED; the rungs stay re-runnable" ;;
        1)  MAPPED=1; LADDER_MEANING="the ladder REFUSED or FAILED — read its output above" ;;
        64) MAPPED=64; LADDER_MEANING="the ladder rejected the command line this bootstrap built for it (a defect here, not yours)" ;;
        *)  MAPPED=1; LADDER_MEANING="undocumented ladder exit — treated as a failure" ;;
    esac
    printf '\n  \342\206\222 migration ladder exited %s: %s\n' "$LADDER" "$LADDER_MEANING"
    printf '  \342\206\222 this bootstrap exits %s\n\n' "$MAPPED"
    if [ "$MAPPED" -ne 0 ]; then
        exit "$MAPPED"
    fi
    ok "$COMP $TAG installed and its migrations forced from floor $MIG_FLOOR"
fi

# ---- PATH persistence ---------------------------------------------------
# On a real install, idempotently add PREFIX/bin to the operator's shell rc so a
# fresh shell finds `burrowee` (the live-VPS `command not found`). bash reads
# ~/.bashrc for INTERACTIVE shells, but a LOGIN shell (ssh) reads the first of
# ~/.bash_profile / ~/.bash_login / ~/.profile and does NOT auto-source ~/.bashrc
# — so write to both the interactive rc and the login file, else PATH is missing
# over ssh. An unset/unknown $SHELL defaults to the bash files. Fault-tolerant:
# an unwritable rc must never abort the script (the bins are already installed).
#
# SKIPPED ENTIRELY FOR THE GATEWAY AND THE EDGE: they install to /usr/local/bin,
# which is already on every PATH, and $PREFIX is empty for them — "$PREFIX/bin"
# would expand to "/bin", a directory this script has no business writing into
# anyone's rc.
#
# Skipped as root, for all components: this script does not edit root's shell
# rc. Note what that means for cli/agent and is not papered over here — a root
# install of those lands in $PREFIX/bin, i.e. /root/.local/bin under root's
# $HOME, which root's PATH does not include, and no marker is written to say so.
# That gap predates this comment; the previous version of it claimed such an
# install "lands in /usr/local/bin (already on PATH)", which no code has ever
# implemented.
if [ "$COMP" != gateway ] && [ "$COMP" != edge ] && [ -z "${BURROWEE_UNINSTALL:-}" ] && [ -z "${BURROWEE_NO_PATH_EDIT:-}" ] && [ "$(id -u)" != 0 ]; then
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

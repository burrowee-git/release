#!/bin/sh
# gen-bootstraps.sh — generate the self-contained outer bootstraps from their
# respective templates, plus the per-component OS-dependency preflight.
#
# For each of cli/gateway/edge/agent, THREE files:
#   <comp>/install.sh    resolve + verify + unzip + run the inner installer
#   <comp>/upgrade.sh    the same, then migrations/upgrade.sh out of the same kit
#   <comp>/preflight.sh  the OS-dependency installer both of the above sha256-pin
# plus, for edge and gateway ONLY, a FOURTH:
#   <comp>/updater.install.sh  the same resolve + verify + unzip, then run the
#                               inner updater.install.sh instead of install.sh —
#                               the narrow recovery tool that reinstalls only the
#                               updater (binary + unit) on a host that already
#                               has the component. edge and gateway are the two
#                               components with a supervised updater SERVICE to
#                               recover; cli's updater is a one-shot binary with
#                               no service, and agent has no updater installer
#                               at all — see UPDATER_INSTALL_COMPONENTS below.
# plus relay/install.sh, from the private gated-channel template.
#
# install.sh, upgrade.sh and updater.install.sh are ONE template under a @MODE@
# substitution, not three files: the pinned preflight sha256, the baked pubkey,
# the version floor and the minisign gate are what make it the trust anchor, and
# a second (or third) copy of those is a copy that drifts. @MODE@ decides only
# which inner script the verified kit hands off to at the end — see
# tools/bootstrap.template.sh's own header for the three-way table.
#
# cli/gateway/edge/agent use tools/bootstrap.template.sh (public GitHub-release
# channel) + tools/preflight.template.sh (OS-dep installer). relay uses
# tools/relay-bootstrap.template.sh (private gated channel: challenge-response
# ed25519 signing + gated downloads) and has no preflight — and no
# updater.install mode either: relay is a different CHANNEL (gated,
# challenge-response), not a different mode of the public template, so it is
# excluded by construction (its own loop below) rather than by an exception
# threaded through this one.
#
# Each generated file is byte-identical within its template family except for
# the @COMP@ and @PUBKEY@ substitutions. The outer bootstrap is THE TRUST
# ANCHOR, so the baked @PUBKEY@ must be the real release signing pubkey before
# activation. The outer bootstrap also pins its preflight's sha256
# (@PREFLIGHT_SHA256@) — preflight runs before minisign exists, so the pin is
# its integrity anchor; ORDER: render preflight first, then bake its hash in.
#
# Pubkey resolution (first that exists wins):
#   1. $BURROWEE_PUBKEY_FILE   (explicit override; used by the offline E2E test)
#   2. burrowee-release.pub    (the REAL release signing pubkey — Phase 7/A2)
#   3. tools/testkeys/test.pub (the local TEST key — Phase 5a)
#   4. none -> a clearly-marked TEMP placeholder is baked in, and the generated
#      bootstraps WILL refuse to run (the runtime guards on *TEMP*). Regenerate
#      once a real key exists.
#
# The @PUBKEY@ value is the base64 key line of a minisign .pub file (the last
# non-comment line) — exactly what `minisign -V -P <pubkey>` expects inline.
#
# The public bootstraps also bake @MIN_VERSION@ — the component's last published
# stamp, read from versions/<comp>.stamp. That is the installer's version floor:
# a tag resolved from the network (a GH_PROXY mirror or the console catalog when
# GitHub's API is unreachable) is refused if it is older, so the party serving
# the artifacts cannot also pick an arbitrary older release to serve. release.sh
# re-runs this script on every cut, AFTER the stamp file is written, so the
# published install.sh always carries the version it was published beside.
#
# ANY merge or rebase that brings in a newer versions/*.stamp must be followed by
# a re-run of this script (and a commit of the regenerated bootstraps) — the
# stamp files and the baked floors are two halves of one fact, and only this
# script keeps them in step. tools/test-version-floor.sh and
# tools/test-tag-binding.sh both fail while they disagree.
#
#   BURROWEE_MIN_VERSION   test-only override for the baked floor (mirrors
#                          BURROWEE_PUBKEY_FILE). Offline tests fabricate their
#                          own release stamps, which have nothing to do with the
#                          repo's real versions/<comp>.stamp.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TEMPLATE="$ROOT/tools/bootstrap.template.sh"
RELAY_TEMPLATE="$ROOT/tools/relay-bootstrap.template.sh"
PREFLIGHT_TEMPLATE="$ROOT/tools/preflight.template.sh"
[ -f "$TEMPLATE" ] || { echo "✗ missing template: $TEMPLATE" >&2; exit 1; }
[ -f "$RELAY_TEMPLATE" ] || { echo "✗ missing relay template: $RELAY_TEMPLATE" >&2; exit 1; }
[ -f "$PREFLIGHT_TEMPLATE" ] || { echo "✗ missing preflight template: $PREFLIGHT_TEMPLATE" >&2; exit 1; }

# sha256 of a file (shasum on mac, sha256sum on linux) — for the preflight pin.
sha256_of() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else echo "✗ neither shasum nor sha256sum found — cannot compute preflight pin" >&2; exit 1; fi
}

# ---- resolve the pubkey -------------------------------------------------
pubfile=""
for cand in "${BURROWEE_PUBKEY_FILE:-}" "$ROOT/burrowee-release.pub" "$ROOT/tools/testkeys/test.pub"; do
    [ -n "$cand" ] || continue
    if [ -f "$cand" ]; then pubfile="$cand"; break; fi
done

if [ -n "$pubfile" ]; then
    # last non-empty, non-comment line = the base64 key line
    PUBKEY="$(grep -v '^untrusted comment:' "$pubfile" | grep -v '^[[:space:]]*$' | tail -n1)"
    [ -n "$PUBKEY" ] || { echo "✗ could not extract a pubkey line from $pubfile" >&2; exit 1; }
    echo "→ baking pubkey from: $pubfile"
else
    # No key file anywhere yet. Bake a TEMP placeholder — the runtime guard in
    # the template aborts on *TEMP* so these can never silently install.
    PUBKEY="RWTEMP_PLACEHOLDER_REGENERATE_AFTER_PHASE5A_OR_A2_xxxxxxxxxxxx"
    echo "! no pubkey file found (burrowee-release.pub / tools/testkeys/test.pub)" >&2
    echo "! baking a TEMP placeholder — generated bootstraps will REFUSE to run." >&2
    echo "! create the key (Phase 5a: minisign -G ... or Phase A2) and re-run." >&2
fi

# ---- resolve the version floor ------------------------------------------
# min_version_of <comp> — the stamp to bake as @MIN_VERSION@. $BURROWEE_MIN_VERSION
# overrides for tests; otherwise versions/<comp>.stamp, which release.sh writes
# before it regenerates the bootstraps. Fails loudly rather than baking anything
# the runtime guard would have to reject: a bootstrap without a usable floor
# cannot resolve a version at all, so shipping one is not an option.
min_version_of() {
    _mv_comp="$1"
    if [ -n "${BURROWEE_MIN_VERSION:-}" ]; then
        _mv="${BURROWEE_MIN_VERSION}"
        _mv_src="\$BURROWEE_MIN_VERSION"
    else
        _mv_file="$ROOT/versions/${_mv_comp}.stamp"
        [ -f "$_mv_file" ] \
            || { echo "✗ missing $_mv_file — cannot bake ${_mv_comp}'s version floor (cut the component, or set BURROWEE_MIN_VERSION for a test render)" >&2; exit 1; }
        _mv="$(tr -d '[:space:]' < "$_mv_file")"
        _mv_src="$_mv_file"
    fi
    # Validated whatever the source: the leading X.Y.Z must be numeric, because
    # that is all the runtime comparison reads and it fails closed on anything
    # else. Baking a floor the shipped installer would have to reject just turns
    # a generator bug into an install-time outage.
    case "${_mv#v}" in
        [0-9]*.[0-9]*.[0-9]*) : ;;
        *) echo "✗ ${_mv_src} holds '${_mv}', which has no numeric X.Y.Z prefix — refusing to bake an uncomparable version floor" >&2; exit 1 ;;
    esac
    printf '%s' "$_mv"
}

# updater.install.sh is rendered for edge and gateway ONLY — named explicitly
# here, not left to whichever components the loop below happens to reach. edge
# and gateway are the two components with a supervised updater SERVICE to
# recover: cli's updater is a one-shot binary with no service
# (inner/cli/install.sh writes no unit and never elevates), and agent has no
# updater installer either. See inner/edge/updater.install.sh and
# inner/gateway/updater.install.sh.
UPDATER_INSTALL_COMPONENTS="edge gateway"

# ---- generate cli/gateway/edge/agent (public GitHub-release channel) ----
# ORDER per comp: render <comp>/preflight.sh FIRST (so we can sha256 it), then
# render <comp>/install.sh baking that hash as @PREFLIGHT_SHA256@. @NGINX@ is 1
# for edge (installs nginx + stream module), 0 for cli/gateway/agent.
for comp in cli gateway edge agent; do
    mkdir -p "$ROOT/$comp"
    case "$comp" in
        edge) nginx=1 ;;
        *)    nginx=0 ;;
    esac

    # (1) preflight — tmp-then-mv atomic write.
    pf_out="$ROOT/$comp/preflight.sh"
    pf_tmp="$pf_out.tmp.$$"
    sed -e "s|@COMP@|$comp|g" -e "s|@NGINX@|$nginx|g" "$PREFLIGHT_TEMPLATE" > "$pf_tmp"
    chmod +x "$pf_tmp"
    mv -f "$pf_tmp" "$pf_out"
    pf_sha="$(sha256_of "$pf_out")"
    echo "✓ wrote $pf_out  (sha256 $pf_sha)"

    # (2) install.sh, upgrade.sh, and — for edge/gateway only —
    # updater.install.sh: all rendered from the SAME template under @MODE@,
    # baking @COMP@, @PUBKEY@, the preflight's @PREFLIGHT_SHA256@ and the
    # @MIN_VERSION@ version floor identically into every one of them. None of
    # these values contains another's placeholder. tmp-then-mv atomic.
    #
    # install/upgrade: BOTH MODES FOR EVERY PUBLIC COMPONENT, not only for
    # those whose release zip ships a migrations/ ladder. Which kits carry one
    # is decided in the COMPONENT repos at their cut; this generator runs at
    # THIS repo's cut and writes a static file served from a URL we advertise.
    # A conditional render would encode a "does <comp> have a ladder" belief
    # here that nothing keeps in step with the zips, and the first time it was
    # wrong the URL would 404 — a 404 being strictly worse than the shipped
    # bootstrap's own refusal, which names the component and the version it
    # just installed. cmd/rkit's TestUpgradeBootstrapsAreExactlyThePublicComponents
    # pins the set.
    #
    # updater.install: ONLY for UPDATER_INSTALL_COMPONENTS (edge gateway),
    # named explicitly above rather than left to whichever components this loop
    # happens to reach — "has a supervised updater service to recover" is a
    # fixed fact about the component, decided at design time, unlike "ships a
    # ladder this cut" above. cmd/rkit's
    # TestUpdaterInstallBootstrapsAreExactlyEdgeAndGateway pins this set too.
    min_version="$(min_version_of "$comp")"
    modes="install upgrade"
    case " $UPDATER_INSTALL_COMPONENTS " in
        *" $comp "*) modes="$modes updater.install" ;;
    esac
    for mode in $modes; do
        out="$ROOT/$comp/$mode.sh"
        tmp="$out.tmp.$$"
        sed -e "s|@COMP@|$comp|g" -e "s|@MODE@|$mode|g" -e "s|@PUBKEY@|$PUBKEY|g" \
            -e "s|@PREFLIGHT_SHA256@|$pf_sha|g" -e "s|@MIN_VERSION@|$min_version|g" \
            "$TEMPLATE" > "$tmp"
        chmod +x "$tmp"
        mv -f "$tmp" "$out"
        echo "✓ wrote $out  (mode $mode, version floor $min_version)"
    done
done

# ---- generate relay (private gated channel) -----------------------------
# Uses the relay-specific template — distinct from the public template above.
# Same @PUBKEY@ trust anchor (minisign integrity layer); @COMP@=relay.
comp=relay
out="$ROOT/$comp/install.sh"
mkdir -p "$ROOT/$comp"
tmp="$out.tmp.$$"
sed -e "s|@COMP@|$comp|g" -e "s|@PUBKEY@|$PUBKEY|g" "$RELAY_TEMPLATE" > "$tmp"
chmod +x "$tmp"
mv -f "$tmp" "$out"
echo "✓ wrote $out  (relay gated-channel bootstrap)"

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
#
# BETA TWINS: for every public component this also renders <comp>/beta.install.sh,
# <comp>/beta.upgrade.sh and (edge/gateway) <comp>/beta.updater.install.sh — the
# SAME template, SAME modes, with @CHANNEL@=beta and the floor read from
# versions/<comp>.beta.stamp instead of versions/<comp>.stamp. That file's
# PRESENCE is the open-beta-cycle flag: when it is absent the twins are not
# rendered, and any beta.*.sh left over from a since-closed cycle is deleted —
# the LOCAL copy, and only that: this script never touches the release host,
# so a beta.*.sh already served from there is untouched by this sweep and
# keeps resolving and installing the last public beta indefinitely (spec §3
# keeps beta tags on GitHub as history, so there is something to resolve to)
# until an operator removes the served file by hand — see tools/RUNBOOK.md
# "Close a cycle". TWO files gate this one state, one per half of it:
# versions/<comp>.beta (the beta semver source, tools/version.sh reads and
# writes it) and versions/<comp>.beta.stamp (the full cut stamp this script
# reads, written by tools/release.sh's beta channel at cut time) — neither is
# written by this script.
#
#   BURROWEE_MIN_VERSION_FILE   override for the FILE min_version_of reads
#                                (mirrors BURROWEE_MIN_VERSION, which overrides
#                                the VALUE outright and wins over both). NOT
#                                test-only: the beta twin loop below sets this
#                                in PRODUCTION to point min_version_of at
#                                versions/<comp>.beta.stamp instead of
#                                versions/<comp>.stamp — the assignment lives
#                                inside a command substitution
#                                ($(BURROWEE_MIN_VERSION_FILE=... min_version_of
#                                ...)), so it cannot leak into the next
#                                component's or channel's stable render. Tests
#                                (test-version-floor.sh etc.) also use it, to
#                                point at a fabricated stamp with nothing to do
#                                with this repo's real versions/*.stamp.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TEMPLATE="$ROOT/tools/bootstrap.template.sh"
RELAY_TEMPLATE="$ROOT/tools/relay-bootstrap.template.sh"
PREFLIGHT_TEMPLATE="$ROOT/tools/preflight.template.sh"
[ -f "$TEMPLATE" ] || { echo "✗ missing template: $TEMPLATE" >&2; exit 1; }
[ -f "$RELAY_TEMPLATE" ] || { echo "✗ missing relay template: $RELAY_TEMPLATE" >&2; exit 1; }
[ -f "$PREFLIGHT_TEMPLATE" ] || { echo "✗ missing preflight template: $PREFLIGHT_TEMPLATE" >&2; exit 1; }

# PUBLIC_COMPONENTS — cli gateway edge agent. Shared with tools/release.sh (its
# sweep-staging widen needs the SAME set this script renders/sweeps for, not a
# second hardcoded copy that can drift from it) — see tools/public_components.sh.
. "$ROOT/tools/public_components.sh"

# sha256 of a file (shasum on mac, sha256sum on linux) — for the preflight pin.
sha256_of() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else echo "✗ neither shasum nor sha256sum found — cannot compute preflight pin" >&2; exit 1; fi
}

MODDIR="$ROOT/tools/modules"

# expand_includes <template> — write <template> to stdout with every line that is
# exactly `@INCLUDE:<name>@` replaced by tools/modules/<name>.sh, wrapped in
# `# BEGIN <name>` / `# END <name>` markers and with the module's own header
# lines dropped. Runs BEFORE the sed substitution pass, so a module may contain
# @COMP@ / @MODE@ / @BRAND@ / @brand@ like any other template text.
#
# The bootstrap is the trust anchor: it is delivered as `curl … | sh` and fetches
# no code. Modules are therefore spliced HERE, at generation time, and never
# sourced at runtime.
#
# The emitted `# BEGIN <name>` / `# END <name>` markers are LOAD-BEARING: one
# or more tools/test-*.sh scripts (e.g. tools/test-checksum-verify.sh) extract
# a module's spliced block out of a GENERATED bootstrap by matching these exact
# marker names verbatim. Renaming a module (and therefore its markers) without
# first grepping tools/test-*.sh for the old name will silently break that
# extraction.
expand_includes() {
    awk -v moddir="$MODDIR" '
        /^@INCLUDE:[a-z0-9-]+@$/ {
            name = substr($0, 10, length($0) - 9 - 1)
            path = moddir "/" name ".sh"
            if ((getline probe < path) < 0) {
                printf("✗ @INCLUDE:%s@ but %s does not exist\n", name, path) > "/dev/stderr"
                exit 1
            }
            close(path)
            printf("# BEGIN %s\n", name)
            while ((getline line < path) > 0) {
                if (line ~ /^# (module|needs|since):/) continue
                print line
            }
            close(path)
            printf("# END %s\n", name)
            next
        }
        { print }
    ' "$1"
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
        _mv_file="${BURROWEE_MIN_VERSION_FILE:-$ROOT/versions/${_mv_comp}.stamp}"
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
for comp in $PUBLIC_COMPONENTS; do
    mkdir -p "$ROOT/$comp"
    case "$comp" in
        edge) nginx=1 ;;
        *)    nginx=0 ;;
    esac

    # (1) preflight — tmp-then-mv atomic write. expand_includes runs OFF the left
    # of any pipeline (assigned via its own redirection) so `set -e` sees its
    # exit status directly — a pipeline's left-hand failure is otherwise
    # invisible under plain `set -eu`. The @INCLUDE: guard runs against the tmp
    # file BEFORE the mv, so a bad render never reaches the file preflight.sh's
    # sha256 gets pinned from, let alone the published path.
    pf_out="$ROOT/$comp/preflight.sh"
    pf_tmp="$pf_out.tmp.$$"
    pf_exp="$pf_out.exp.$$"
    expand_includes "$PREFLIGHT_TEMPLATE" > "$pf_exp"
    sed -e "s|@COMP@|$comp|g" -e "s|@NGINX@|$nginx|g" "$pf_exp" > "$pf_tmp"
    rm -f "$pf_exp"
    grep -q '@INCLUDE:' "$pf_tmp" && { rm -f "$pf_tmp"; echo "✗ unexpanded @INCLUDE in $pf_out" >&2; exit 1; }
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
    modes="install upgrade"
    case " $UPDATER_INSTALL_COMPONENTS " in
        *" $comp "*) modes="$modes updater.install" ;;
    esac

    # ---- stable, then beta (twin) ---------------------------------------
    # SAME modes loop, wrapped in a channel loop: stable always renders (as
    # today — @COMP@/install.sh etc., prefix ""); beta renders its
    # @COMP@/beta.install.sh (etc.) twin ONLY while a beta cycle is open, i.e.
    # versions/<comp>.beta.stamp exists — that file's presence is the open-cycle
    # flag (see the header comment: it is the cut-time companion to
    # versions/<comp>.beta, which tools/version.sh owns). When it is absent,
    # any beta.*.sh left over from a since-closed cycle is deleted: the
    # LOCAL copy only — the served one, if any, is untouched (this script
    # never deletes from the release host) and keeps resolving the last
    # public beta indefinitely until an operator removes it by hand, see
    # tools/RUNBOOK.md "Close a cycle". The sweep globs beta.*.sh rather than
    # walking the current $modes, so a component that later leaves
    # UPDATER_INSTALL_COMPONENTS still loses its stray beta.updater.install.sh.
    for channel in stable beta; do
        if [ "$channel" = beta ]; then
            beta_stamp="$ROOT/versions/${comp}.beta.stamp"
            if [ ! -f "$beta_stamp" ]; then
                stale=""
                for f in "$ROOT/$comp"/beta.*.sh; do
                    [ -e "$f" ] || continue   # glob matched nothing
                    rm -f "$f"
                    stale="$stale $(basename "$f")"
                done
                if [ -n "$stale" ]; then
                    echo "→ $comp: no beta cycle open ($beta_stamp absent) — removed stale:$stale"
                else
                    echo "→ $comp: no beta cycle open ($beta_stamp absent) — beta twins not rendered"
                fi
                continue
            fi
            min_version="$(BURROWEE_MIN_VERSION_FILE="$beta_stamp" min_version_of "$comp")"
            prefix="beta."
        else
            min_version="$(min_version_of "$comp")"
            prefix=""
        fi
        for mode in $modes; do
            out="$ROOT/$comp/${prefix}${mode}.sh"
            tmp="$out.tmp.$$"
            exp="$out.exp.$$"
            # expand_includes runs OFF the left of the pipeline (its own redirection,
            # not a pipe) so `set -e` sees its exit status: a missing module makes
            # awk exit 1 without ever printing the `@INCLUDE:` line, so the
            # post-render grep guard below has nothing left to catch — only a
            # directly-checked exit status catches that failure. The guard still
            # runs, against the tmp file BEFORE the mv, to catch the OTHER failure
            # shape: a malformed include name (e.g. `@INCLUDE:Helpers@`) that the
            # awk regex declines to match and so passes through literally.
            expand_includes "$TEMPLATE" > "$exp"
            sed -e "s|@COMP@|$comp|g" -e "s|@MODE@|$mode|g" -e "s|@PUBKEY@|$PUBKEY|g" \
                -e "s|@PREFLIGHT_SHA256@|$pf_sha|g" -e "s|@MIN_VERSION@|$min_version|g" \
                -e "s|@CHANNEL@|$channel|g" \
                -e "s|@BRAND@|BURROWEE|g" -e "s|@brand@|burrowee|g" \
                "$exp" > "$tmp"
            rm -f "$exp"
            grep -q '@INCLUDE:' "$tmp" && { rm -f "$tmp"; echo "✗ unexpanded @INCLUDE in $out" >&2; exit 1; }
            chmod +x "$tmp"
            mv -f "$tmp" "$out"
            echo "✓ wrote $out  (channel $channel, mode $mode, version floor $min_version)"
        done
    done
done

# ---- generate relay (private gated channel) -----------------------------
# Uses the relay-specific template — distinct from the public template above.
# Same @PUBKEY@ trust anchor (minisign integrity layer); @COMP@=relay.
comp=relay
out="$ROOT/$comp/install.sh"
mkdir -p "$ROOT/$comp"
tmp="$out.tmp.$$"
exp="$out.exp.$$"
expand_includes "$RELAY_TEMPLATE" > "$exp"
sed -e "s|@COMP@|$comp|g" -e "s|@PUBKEY@|$PUBKEY|g" \
    -e "s|@BRAND@|BURROWEE|g" -e "s|@brand@|burrowee|g" \
    "$exp" > "$tmp"
rm -f "$exp"
grep -q '@INCLUDE:' "$tmp" && { rm -f "$tmp"; echo "✗ unexpanded @INCLUDE in $out" >&2; exit 1; }
chmod +x "$tmp"
mv -f "$tmp" "$out"
echo "✓ wrote $out  (relay gated-channel bootstrap)"

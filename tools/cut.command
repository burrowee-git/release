#!/bin/bash
# cut.command — run this repo's release cut in a DESKTOP session.
#
# Not a release step. It launches tools/release.sh unmodified; every decision
# about what a cut does still lives there. This exists for one reason:
#
#   Signing and notarizing are different capabilities. rcodesign is pure
#   userspace and signs in any session. notarytool reaches Apple through
#   CFNetwork/AppSSO, which needs a per-user bootstrap namespace — in a
#   background/daemon-hosted shell it does not crash politely, it SIGTRAPs with
#   no submission id, and release.sh can only report `status: unknown`. That
#   reads like a vendor outage and is not one.
#
# LaunchServices opens a .command in the desktop's own terminal, which IS such a
# session — no Apple Events, no TCC prompt, no sudo. Hence the extension: this
# file must be openable, not merely executable.
#
#   chmod +x tools/cut.command && open tools/cut.command
#
# Inputs (both OUTSIDE this repo or ignored by it — this file holds flow only,
# never a path, binary name, credential, or component list):
#
#   ~/.agents/local/release.env  machine facts: PATH to the toolchain, signing and
#                             notarization backends, non-interactive flags.
#                             Override with CUT_ENV.
#   .cut-request              what to cut, written per run. Override with
#                             CUT_REQUEST. Shape:
#                                 COMPONENTS="edge cli"
#                                 FLAGS="--public"
#
# Output: .cut.log, ending in CUT-EXIT:<code> so a watcher can block on it
# rather than guess when the run finished.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

LOG="${CUT_LOG:-$REPO_ROOT/.cut.log}"
: > "$LOG"

say() { echo "$@" | tee -a "$LOG"; }
die() { say "✗ $*"; say "CUT-EXIT:1"; exit 1; }

# 1. Session. Checked FIRST and refused loudly: the whole point of this file is
#    that the wrong session builds and signs for minutes before dying at notarize.
DOMAIN="$(launchctl managername 2>/dev/null || echo unknown)"
say "session-domain: ${DOMAIN}"
[ "${DOMAIN}" = "Aqua" ] || die "not a desktop session (need Aqua, got ${DOMAIN}) — 'open' this file, do not run it from a shell"

# 2. Environment. Loaded, never embedded.
ENV_FILE="${CUT_ENV:-$HOME/.agents/local/release.env}"
[ -r "${ENV_FILE}" ] || die "env file not readable: ${ENV_FILE}"
# shellcheck source=/dev/null
. "${ENV_FILE}"
say "env: ${ENV_FILE}"

# 3. Request.
REQUEST="${CUT_REQUEST:-$REPO_ROOT/.cut-request}"
[ -r "${REQUEST}" ] || die "request file not readable: ${REQUEST}"
COMPONENTS=""; FLAGS=""
# shellcheck source=/dev/null
. "${REQUEST}"
[ -n "${COMPONENTS}" ] || die "request names no COMPONENTS: ${REQUEST}"
say "request: ${COMPONENTS} [${FLAGS}]"

# 4. Cut each component, pushing its marker before the next one starts.
#
#    release.sh deliberately never pushes, and its cut-origin guard refuses to
#    cut while this repo is ahead of its remote. Both are correct on their own
#    and together they strand a batch: component #1 publishes, leaves a marker
#    commit unpushed, and component #2 aborts on the guard. Pushing here is what
#    lets a batch run unattended.
for comp in ${COMPONENTS}; do
    say ""
    say "── cut: ${comp} ──"
    # shellcheck disable=SC2086
    bash tools/release.sh "${comp}" ${FLAGS} 2>&1 | tee -a "$LOG"
    rc="${PIPESTATUS[0]}"
    [ "${rc}" -eq 0 ] || { say "✗ ${comp} failed (exit ${rc}) — later components NOT cut"; say "CUT-EXIT:${rc}"; exit "${rc}"; }

    # Push ONLY a marker commit over a clean tree. An unattended push to a
    # public repo should be able to publish the thing it was built to publish
    # and nothing else — if the cut ever leaves the tree in another shape, that
    # is a bug to look at, not to push.
    if [ -n "$(git status --porcelain)" ]; then
        die "${comp} cut left an unclean tree — refusing to push; inspect before continuing"
    fi
    subject="$(git log -1 --format=%s)"
    case "${subject}" in
        "[RELEASED: ${comp}]"*)
            git push origin HEAD 2>&1 | tee -a "$LOG"
            [ "${PIPESTATUS[0]}" -eq 0 ] || die "marker push failed for ${comp}"
            say "✓ ${comp} marker pushed"
            ;;
        *)
            say "→ ${comp}: HEAD is not a [RELEASED: ${comp}] marker — nothing to push"
            ;;
    esac
done

say ""
say "CUT-EXIT:0"

#!/bin/bash
# beta-release.command — run this repo's BETA cut in a DESKTOP session.
#
# Not a release step, and not a second launcher: it selects ONE documented input
# and hands off to tools/release.command UNMODIFIED. Every decision about what a
# cut does still lives in tools/release.sh, and every guard — Aqua session, not
# root, not SSH, LaunchServices' tty, the single-release lock — still runs there,
# once, because this file execs into it rather than reimplementing any of it.
#
# It exists because release.command's inputs are environment-only and
# LaunchServices starts an opened .command with a FRESH environment. There is no
# way to say "use the beta request" through `open`, so the beta cut was a
# hand-typed export in a desktop shell — and the failure when it is forgotten is
# silent, not loud: RELEASE_REQUEST unset falls back to .release-request, which
# is the STABLE request, and the run cheerfully cuts a different component on a
# different channel. A wrong cut that publishes is not a mistake you undo.
#
#   open tools/beta-release.command    # committed 100755; no chmod needed
#
# Inputs: .beta-release-request — this file's whole purpose — plus everything
# tools/release.command already documents (RELEASE_ENV, RELEASE_LOG,
# KEEP_WINDOW), which pass through untouched. RELEASE_REQUEST is deliberately
# NOT honoured from the environment here: a launcher whose name promises beta
# must not be steerable into cutting something else.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)" || exit 1
REPO_ROOT="$(cd "${HERE}/.." && pwd)" || exit 1
REQUEST="${REPO_ROOT}/.beta-release-request"
[ -r "${REQUEST}" ] || { echo "✗ beta request not readable: ${REQUEST}" >&2; exit 1; }

# The name on this file is a promise about the channel. Verify it against the
# request rather than trusting the filename: a request edited to CHANNEL="stable"
# would otherwise reach release.sh through the beta door, and release.command
# validates only that the channel is one of the two, not which one it is.
req_channel="$(. "${REQUEST}"; printf '%s' "${CHANNEL:-stable}")" \
    || { echo "✗ cannot read ${REQUEST}" >&2; exit 1; }
[ "${req_channel}" = beta ] \
    || { echo "✗ ${REQUEST} declares CHANNEL=\"${req_channel}\", not beta — use tools/release.command for a stable cut" >&2; exit 1; }

export RELEASE_REQUEST="${REQUEST}"
exec "${HERE}/release.command"

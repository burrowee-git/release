#!/usr/bin/env bash
# trustcomment.sh — the minisign TRUSTED COMMENT every Burrowee release is
# signed with. Sourced by tools/release.sh; cross-checked against
# cmd/rkit/build.go's trustedComment() — and against the outer bootstrap's
# reconstruction of it — by cmd/rkit/trusted_comment_test.go.
#
# WHY THIS FILE EXISTS
# The trusted comment is the ONLY version-bearing field the outer bootstrap can
# verify: the zip names and SHA256SUMS.txt are both version-independent, so
# after the signature checks out the bootstrap asserts this exact string against
# the tag it resolved. That is what stops an older, genuinely signed release
# from being served in place of the requested one.
#
# It used to be written in four places with nothing comparing them:
# cmd/rkit/build.go's trustedComment (rkit's cut path), and THREE open-coded
# `-t "burrowee … ${stamp}"` arguments in tools/release.sh — two of which
# hardcoded `relay` instead of the component in scope. build.go's comment said
# "the two must never diverge"; nothing enforced it, and there were not two.
#
# The failure mode is why this outranked the payload duplication it follows:
# a writer/verifier drift is not caught by a test or a review, it is caught by
# every user's install failing — after the release is signed, notarized,
# published and pulled. It cannot be quietly re-cut; the bad artifact is
# already out and the installer refuses it.
#
# Two copies rather than one, for the same reason tools/payload.sh and
# tools/binmap.sh have two: one side is bash on the operator's machine, the
# other is Go compiled into rkit, and neither can call the other during a cut
# without making the shell path depend on a binary it does not need.
#
# THE VERIFIER IS DELIBERATELY NOT A THIRD CALLER. tools/bootstrap.template.sh
# reconstructs the string from its own baked $COMP and the $TAG it resolved
# (`expect="burrowee $COMP ${TAG#*/}"`) instead of being handed the writer's
# answer. That independence is the check: a verifier fed the writer's output
# agrees with a buggy writer and verifies nothing. It also cannot be otherwise
# — the bootstrap is a standalone POSIX-sh script curl'd to a stranger's
# machine, running months later against releases cut by a later release.sh, so
# there is no moment at which the two could share code. So the agreement is
# PINNED instead of collapsed: cmd/rkit/trusted_comment_test.go executes the
# real `expect=` line lifted out of the template and compares it, per
# component, with the writers.
#
# RELAY IS NOT A SPECIAL FORMAT. Its two sites hardcoded `relay` only because
# both sit inside relay-only functions that already have `comp=relay` two lines
# up; the string is `burrowee relay <stamp>` either way. Relay's own bootstrap
# (tools/relay-bootstrap.template.sh) does no tag binding at all — the gated
# channel serves stamp-less latest.*.zip names — so relay's comment is written
# but not verified. Adding that binding is a fine idea; the test file above
# says what has to move with it.

# trusted_comment <component> <stamp> — the exact `-t` value, no trailing
# newline. Fails closed on a missing or empty argument rather than emitting a
# short string: a release signed `burrowee cli ` with no stamp verifies fine
# and then fails every install's version binding, which is the outage this
# whole file exists to prevent.
trusted_comment() {
    if [ "$#" -ne 2 ] || [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
        echo "✗ trusted_comment needs <component> <stamp> (got $#: '${1:-}' '${2:-}')" >&2
        return 2
    fi
    printf 'burrowee %s %s' "$1" "$2"
}

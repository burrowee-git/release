#!/usr/bin/env bash
# targets.sh — which platforms a cut builds, as data plus predicates sourced by
# tools/release.sh.
#
# This lives beside release.sh rather than inside it for the same reason
# apple_sign.sh and release_origin.sh do: tools/targets.test.sh exercises it
# directly, with no part of the release path running.
#
# It was extracted after the platform set drifted in production. The first beta
# cut published four zips out of five because internal/register/publish.go
# carried its own hardcoded copy of this list and never learned about the fifth
# platform; the console minted a presigned URL for the missing one and every
# Intel Mac below macOS 12 got a 404 from a cut that reported success. A
# platform table that several places restate is a table that drifts, so this is
# the one place release.sh reads it from — and now the one place a test can
# reach.

# TARGETS — every platform a public component ships, as "<os> <arch> [variant]"
# triples. The empty variant is the stock build; "legacy" is the crypto/x509
# overlay build for Intel Macs below macOS 12 (tools/legacy/darwin/).
TARGETS=(
    "darwin arm64"
    "darwin amd64"
    "darwin amd64 legacy"
    "linux arm64"
    "linux amd64"
)

# plat_of <os> <arch> <variant> — the one spelling of the platform string used
# for build output dirs, the dispatcher cache, assembly dirs, zip names, the
# relay .latest set and the artifacts.json/register key: "<os>-<arch>" for the
# empty (stock) variant, "<os>-<arch>-<variant>" otherwise. <variant> is
# frequently the empty string — bash 3.2's `read` into three variables from a
# two-word TARGETS entry already leaves the third empty, so no sentinel value
# is needed to represent "no variant" in the triples above.
plat_of() { printf '%s-%s%s' "$1" "$2" "${3:+-$3}"; }

# ships_target <comp> <variant> — whether <comp> builds this TARGETS variant.
# True for every (comp, variant) pair except relay's legacy one.
#
# The four base platforms are universal. The fifth, variant=legacy
# (darwin-amd64-legacy), exists so Intel Macs below macOS 12 get a binary that
# does not abort in dyld — and that is a PUBLIC-INSTALL concern. relay is
# gated: it is never self-installed by a user off release.burrowee.com, it runs
# on relay nodes the operator provisions, and none of those is a pre-2021 Mac.
# Building it cost a full darwin build, an rcodesign pass and an Apple notary
# submission per relay cut, for a zip nothing could ask for.
#
# Only do_release_relay consults this — every other TARGETS loop belongs to a
# public component and ships all five. register_staged needs no change: it
# already omits an artifact whose zip is absent from the stage rather than
# failing, so relay's row simply carries four platforms. The console needs none
# either: presignAllPlatforms treats a missing legacy artifact as non-fatal for
# that platform alone, so a relay mint renders an install.sh with no legacy arm
# and a legacy host hits its catch-all fail() — the correct answer for a
# component that does not run there.
ships_target() {
    if [ "$1" = relay ] && [ "$2" = legacy ]; then
        return 1
    fi
    return 0
}

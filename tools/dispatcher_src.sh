#!/usr/bin/env bash
# dispatcher_src.sh — which dispatcher a cut bundles, as predicates sourced by
# tools/release.sh.
#
# The dispatcher is bundled into every component's cut rather than cut on its
# own, so it has no --channel of its own and used to be pinned to stable in
# three separate places: the source tree it was built from, the version file it
# was numbered from, and the stamp file its result was recorded into. A beta cut
# therefore bundled the dispatcher built from `main`, numbered from
# versions/burrowee, and WROTE versions/burrowee.stamp — stable state mutated by
# a beta cut, and dispatcher work on the beta branch never reaching a beta build
# at all. All three now follow the cut's channel.
#
# Split out for the same reason as tools/release_origin.sh: these are testable
# predicates, and tools/dispatcher_src.test.sh exercises them directly with no
# part of the release path running.

# disp_stamp_file <repo-root> — where this cut's dispatcher stamp is recorded.
disp_stamp_file() {
    if [ "${CHANNEL:-stable}" = beta ]; then printf '%s/versions/burrowee.beta.stamp' "$1"
    else printf '%s/versions/burrowee.stamp' "$1"; fi
}

# disp_version_rel — the version file this cut numbers the dispatcher from,
# repo-relative. Named in the operator hint, so the hint can never point at a
# file the cut is not using.
disp_version_rel() {
    if [ "${CHANNEL:-stable}" = beta ]; then printf 'versions/burrowee.beta'
    else printf 'versions/burrowee'; fi
}

# disp_channel_args — the --channel pair to pass tools/version.sh, or nothing.
# Empty for stable so the stable invocation stays byte-identical to what it was.
disp_channel_args() {
    [ "${CHANNEL:-stable}" = beta ] && printf '%s' "--channel beta"
    return 0
}

#!/usr/bin/env bash
# binmap.sh — WHICH BINARIES each Burrowee component carries, and the Go package
# each one is built from. Sourced by tools/build.sh (what gets BUILT) and
# tools/release.sh (what the ZIP CARRIES); cross-checked against
# internal/relconfig's Bins by internal/relconfig/binmap_cross_check_test.go.
#
# WHY THIS FILE EXISTS
# This fact used to be stated THREE times with nothing comparing them:
# tools/build.sh's MAP (bin:pkg, what gets built), tools/release.sh's bins_for
# (names only, what gets copied into the zip), and internal/relconfig.Bins
# (rkit's build path, whose result is BOTH built and packaged). relconfig.go
# even said "mirroring tools/build.sh" — asserted in a comment, enforced
# nowhere.
#
# The dangerous direction is the same one that shipped gateway v0.2.0 with no
# migrations/ in it: a component gains a binary in the BUILD list but not in the
# PACKAGE list, so it is built, Developer-ID signed, notarized — and silently
# left out of the payload. The reverse fails closed (the assembly `cp` errors on
# a missing file). Nothing failed on the dangerous direction.
#
# So the two shell copies are collapsed into the one table below, which both
# scripts read, and the remaining Go copy is pinned to it by a test that runs
# under an ordinary `go test ./...`. Two copies rather than one for the same
# reason tools/payload.sh has two: one side is bash on the operator's machine,
# the other is Go compiled into rkit, and neither can call the other during a
# cut without making the shell path depend on a binary it does not need.
#
# THE DISPATCHER IS NOT A RELEASE COMPONENT. `burrowee` has a row here because
# it is a build target — tools/release.sh's build_dispatcher runs this script
# with COMP=burrowee, and rkit calls relconfig.Bins("burrowee", …) — but it is
# never a MEMBER of another component's bin list. Every component zip carries
# the dispatcher, copied in by literal name from its own separately-stamped
# build on both paths. Do not "fix" that asymmetry: it is the real shape.

# bin_table — one row per build target: "<component> <bin>:<pkg> [<bin>:<pkg> …]".
# The package is relative to the component's source worktree; relay's cli and
# updater live in the NESTED cli module, which build.sh enters (build_dir=$SRC/cli,
# pkg=".${pkg#./cli}") and relconfig expresses as SubDir:"cli" — the same fact,
# written the way each side needs it.
bin_table() {
    printf '%s\n' \
        "cli burrowee-cli:./cmd/burrowee-cli burrowee-cli-updater:./cmd/burrowee-cli-updater" \
        "gateway burrowee-gateway:./cmd/burrowee-gateway burrowee-gateway-cli:./cmd/burrowee-gateway-cli burrowee-gateway-console:./cmd/burrowee-gateway-console burrowee-register:./cmd/burrowee-register burrowee-gateway-updater:./cmd/burrowee-gateway-updater" \
        "edge burrowee-edge:./cmd/burrowee-edge burrowee-edge-cli:./cmd/burrowee-edge-cli burrowee-edge-updater:./cmd/burrowee-edge-updater" \
        "agent burrowee-agent:./cmd/burrowee-agent" \
        "relay burrowee-relay:./cmd/burrowee-relay burrowee-relay-cli:./cli burrowee-relay-updater:./cli/cmd/burrowee-relay-updater" \
        "burrowee burrowee:."
}

# bin_components — every component bin_table knows, one per line, in table order.
# Pinned to internal/relconfig.Components by the cross-check test.
bin_components() {
    bin_table | awk '{ print $1 }'
}

# bin_map <comp> — that component's "bin:pkg" pairs, space-separated on one line.
# Unknown component: names the ones that exist and exits 2 (fail closed — a cut
# that cannot resolve its own binary list must not proceed to build one).
bin_map() {
    bin_table | awk -v want="$1" '
        { all = all (all == "" ? "" : "|") $1 }
        $1 == want { $1 = ""; sub(/^[ \t]+/, ""); row = $0; found = 1 }
        END {
            if (!found) {
                printf "✗ unknown component: %s (want %s)\n", want, all > "/dev/stderr"
                exit 2
            }
            print row
        }'
}

# bins_for <comp> — that component's binary NAMES, space-separated on one line.
#
# Derived from bin_map rather than listed again: the zip carries exactly what
# was built, and the whole point of this file is that those two cannot be
# separately edited. tools/release.sh's assembly loops and register_staged both
# read this.
bins_for() {
    local map pair names=""
    map="$(bin_map "$1")" || return $?
    # shellcheck disable=SC2086  # ${map} is an intentional space-list of bin:pkg pairs; word-splitting is the point.
    for pair in ${map}; do
        names="${names}${names:+ }${pair%%:*}"
    done
    printf '%s' "${names}"
}

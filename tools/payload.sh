#!/usr/bin/env bash
# payload.sh — what rides in a component zip BEYOND its binaries, the
# dispatcher and install.sh, plus the assertion that proves it actually did.
# Sourced by tools/release.sh; exercised directly by tools/payload.test.sh.
#
# WHY THIS FILE EXISTS
# The same payload is assembled by two code paths: this shell orchestrator and
# cmd/rkit/assemble.go (extraPayload). Gateway v0.2.0.2026.08.07 was cut through
# the shell path, whose `zip -j` junks paths and skips directories outright — so
# migrations/ silently did not ship, and every host upgrading to the release
# whose entire purpose was to relocate its state ran update.sh's
# "no migrations/run.sh in this release — skipping state migrations" branch. The
# artifact was signed, notarized and published before anyone could see it.
#
# So the extras manifest lives here ONCE, as data both the staging code and the
# gate read, and cmd/rkit/payload_manifest_test.go cross-checks this manifest
# against extraPayload's so the two assembly paths cannot drift again.

# payload_file_extras <comp> — flat payload members (zip root), one per line.
#
# The updaters run `sh ./update.sh` (service update) and, where they self-update
# via a script rather than an in-process binary swap, `sh ./updater.update.sh`,
# both with cwd = the unzipped bundle — so these must ride alongside the bins.
# gateway + cli self-update in-process (UpgradeSelf/ApplyUpdaterBinary) and have
# no updater.update.sh in their source at all. Mirrors extraPayload's switch.
payload_file_extras() {
    case "$1" in
        edge|relay) printf '%s\n' update.sh updater.update.sh ;;
        gateway|cli) printf '%s\n' update.sh ;;
    esac
}

# payload_dir_extras <comp> — DIRECTORY-shaped payload members, one per line.
#
# These are the members `zip -j` cannot carry: it junks paths and skips
# directories entirely, so each of these needs a second, recursive `zip -r` pass
# to keep its path inside the archive. Listing them here rather than as two
# open-coded `if [ "${comp}" = … ]` blocks is the point: edge/covers had the
# extra pass, gateway/migrations did not, and nothing connected the two.
payload_dir_extras() {
    case "$1" in
        edge)    printf '%s\n' covers ;;
        gateway) printf '%s\n' migrations ;;
    esac
}

# payload_manifest <comp> <src-dir> — every extra payload member's zip-member
# name, one per line, in assembly order.
#
# <src-dir> is the COMPONENT source worktree; the gateway's migrations are
# discovered there by glob rather than listed, so adding a migration stays a
# gateway-repo change. edge's covers come from the separate edge.web tree and
# are emitted by name (their content, not their names, depends on that tree).
payload_manifest() {
    local comp="$1" src="$2" s p
    for s in $(payload_file_extras "${comp}"); do
        printf '%s\n' "${s}"
    done
    case "${comp}" in
        gateway)
            for p in "${src}"/migrations/*.sh; do
                [ -f "${p}" ] || continue
                printf 'migrations/%s\n' "$(basename "${p}")"
            done
            ;;
        edge)
            printf '%s\n' covers/admin.html covers/default.html
            ;;
    esac
}

# stage_gateway_migrations <src-dir> <assemble-dir> — copy the gateway's whole
# migrations/ tree into the staged payload dir.
#
# run.sh is the ladder runner install.sh and update.sh invoke; every migration
# beside it ships too, because a host may be upgrading across several releases
# at once and walks the whole ladder in one go. An empty/absent migrations/ dir
# is a hard error: shipping the gateway without it is what this file exists to
# prevent.
stage_gateway_migrations() {
    local src="$1" dest="$2" p base found=0
    mkdir -p "${dest}/migrations"
    for p in "${src}"/migrations/*.sh; do
        [ -f "${p}" ] || continue
        base="$(basename "${p}")"
        cp "${p}" "${dest}/migrations/${base}"
        chmod 0755 "${dest}/migrations/${base}"
        found=1
    done
    if [ "${found}" != 1 ]; then
        echo "✗ gateway migrations missing in source: ${src}/migrations" >&2
        return 1
    fi
}

# ledger_migrations <run.sh> — the migration script names the runner's
# MIGRATIONS= ledger declares, in ledger order, one per line.
#
# The ledger is a shell here-string of "<version-this-upgrades-to> <script>"
# rows, oldest first:
#
#     MIGRATIONS="
#     0.2.0 v1_to_v2.sh
#     "
#
# Word-split into (version, script) pairs exactly as the runner splits it, so
# the two cannot disagree about what the ledger says. Only an assignment at
# column 0 counts — that is where the runner writes it and where a commented-out
# copy never is. Mirrors ledgerMigrations in cmd/rkit/assemble.go.
ledger_migrations() {
    awk '
        { line[NR] = $0 }
        /^MIGRATIONS="/ { hits++; start = NR }
        END {
            if (hits == 0) {
                print "no MIGRATIONS=\" assignment found — this is not the migration runner" > "/dev/stderr"
                exit 1
            }
            if (hits > 1) {
                print "more than one MIGRATIONS=\" assignment" > "/dev/stderr"
                exit 1
            }
            rest = substr(line[start], length("MIGRATIONS=\"") + 1)
            for (i = start + 1; i <= NR; i++) rest = rest "\n" line[i]
            q = index(rest, "\"")
            if (q == 0) {
                print "unterminated MIGRATIONS=\" assignment" > "/dev/stderr"
                exit 1
            }
            n = split(substr(rest, 1, q - 1), word, /[ \t\n]+/)
            c = 0
            for (i = 1; i <= n; i++) if (word[i] != "") kept[++c] = word[i]
            if (c % 2 != 0) {
                printf "ledger holds %d words, want (version, script) pairs\n", c > "/dev/stderr"
                exit 1
            }
            for (i = 2; i <= c; i += 2) print kept[i]
        }
    ' "$1"
}

# assert_payload_migrations <comp> <zip> <src-dir> — the build gate.
#
# Reads the FINISHED ZIP, not the staging dir: the bug this catches lived
# entirely in the packaging step, where a correctly staged migrations/ was
# dropped on the floor by `zip -j`. A staging-dir assertion would have passed on
# the release that shipped without it.
#
# No-op for every component but gateway. Fails closed on a missing unzip: a cut
# that cannot verify its own payload must not proceed to sign one.
assert_payload_migrations() {
    local comp="$1" zip_path="$2" src="$3"
    [ "${comp}" = gateway ] || return 0

    if ! command -v unzip >/dev/null 2>&1; then
        echo "✗ unzip not found — cannot verify the gateway payload carries migrations/" >&2
        return 1
    fi
    local members
    if ! members="$(unzip -Z1 "${zip_path}")"; then
        echo "✗ cannot list gateway payload: ${zip_path}" >&2
        return 1
    fi

    if ! printf '%s\n' "${members}" | grep -qxF 'migrations/run.sh'; then
        echo "✗ gateway payload has no migrations/run.sh: ${zip_path}" >&2
        echo "  install.sh and update.sh run the ladder out of the unzipped bundle; without" >&2
        echo "  the runner every upgrade skips its state migrations silently and the daemon" >&2
        echo "  comes back pointed at state that is no longer there." >&2
        return 1
    fi

    local runner="${src}/migrations/run.sh"
    if [ ! -f "${runner}" ]; then
        echo "✗ gateway migration runner missing in source: ${runner}" >&2
        return 1
    fi
    # The zip carries whatever was staged; the LEDGER is what the runner will
    # actually walk. A migration named in MIGRATIONS= but absent from the payload
    # is a row the runner warns about and skips — after which the caller records
    # the version and that rung is gated off on every host, permanently. Nothing
    # downstream can recover it, so the cut is the last place to catch it.
    local named name
    if ! named="$(ledger_migrations "${runner}")"; then
        echo "✗ unparseable gateway migration ledger in ${runner}" >&2
        return 1
    fi
    # shellcheck disable=SC2086  # ${named} is an intentional newline-list of script names; word-splitting is the point.
    for name in ${named}; do
        if ! printf '%s\n' "${members}" | grep -qxF "migrations/${name}"; then
            echo "✗ gateway migration \"${name}\" is named in the ledger of ${runner} but is not in ${zip_path}" >&2
            return 1
        fi
    done
}

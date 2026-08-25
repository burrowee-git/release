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

# stage_payload_extras <comp> <src-dir> <assemble-dir> — copy the component's
# flat payload extras into the staged bundle, executable.
#
# The ONE staging implementation both assembly sites in tools/release.sh use:
# do_release for the four public components, do_release_relay for the private
# one. Relay used to open-code its own list — `for s in install.sh update.sh
# updater.update.sh` — on the grounds that its install.sh comes from the
# COMPONENT source while the public components take theirs from
# inner/<comp>/install.sh, which makes the two loops look unmergeable.
#
# They are not. install.sh is not a manifest member on EITHER side: this file's
# manifest is defined as what rides "beyond its binaries, the dispatcher and
# install.sh", and cmd/rkit/build.go resolves install.sh per component (line
# ~394: inner/<comp>/install.sh, or <src>/install.sh for relay) and hands it to
# assemble() beside the extras, never inside them. Only the extras belong here;
# each caller keeps ownership of where its own install.sh comes from. That is
# what lets relay share the manifest without changing a byte of its payload.
#
# Every extra comes from the component source tree on both paths, so <src-dir>
# is the whole provenance. A declared extra missing from the source is a hard
# error: a payload whose updater then dies on "cannot open ./update.sh" is the
# same class of defect as a gateway shipped without migrations/.
stage_payload_extras() {
    local comp="$1" src="$2" dest="$3" s
    for s in $(payload_file_extras "${comp}"); do
        if [ ! -f "${src}/${s}" ]; then
            echo "✗ ${comp} update script missing in source: ${src}/${s}" >&2
            return 1
        fi
        cp "${src}/${s}" "${dest}/${s}"
        chmod 0755 "${dest}/${s}"
    done
    # The SHARED ladder is staged HERE, from the one function both of release.sh's
    # assembly sites already call, rather than as a third open-coded copy beside
    # them — the open-coded copy is exactly what shipped a gateway with no
    # migrations/ in it.
    #
    # The gateway is not staged here, and that is not an oversight: it has its
    # own explicit stage_gateway_migrations call site, which predates this and
    # delegates to the same implementation. Staging it twice would be harmless
    # but would also change what a bare stage_payload_extras gateway means, and
    # the one thing worth keeping stable about this function is what a caller
    # can assume from calling it.
    if takes_shared_ladder "${comp}"; then
        stage_component_migrations "${comp}" "${src}" "${dest}" || return 1
    fi
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
        edge)    printf '%s\n' covers migrations ;;
        gateway) printf '%s\n' migrations ;;
        cli)     printf '%s\n' migrations ;;
        relay)   printf '%s\n' migrations ;;
    esac
}

# SHARED_MIGRATIONS_DIR — inner/_shared/migrations, the ONE authored copy of the
# migration runner, the sweep library and the rungs that edge, cli and relay
# all take.
#
# THIS IS THE POINT OF THE DIRECTORY. run.sh is ~450 lines of gating logic whose
# every branch fails quietly in a plausible direction; two components each
# carrying their own copy would look identical right up to the release where one
# of them did not. So the shared half is authored once, here, and STAGED into
# each kit at assembly time, while the component half — its ledger and its
# component.conf — stays in the component's own repo, where a new rung belongs.
#
# The gateway is deliberately NOT on this path: its runner lives in the gateway
# repo, has shipped, and does three things no other component needs (stopping a
# daemon so a SQLite store is at rest, pre-flighting the cli's `migrate` verb,
# and resolving which ACCOUNT's pre-split tree holds the host's identity).
#
# Resolved from this file's own location so a caller does not have to know it,
# and overridable only for the suite.
SHARED_MIGRATIONS_DIR="${SHARED_MIGRATIONS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/inner/_shared/migrations}"

# shared_migration_scripts — the shared files staged into every kit that takes
# the shared ladder, one basename per line, sorted. Discovered by glob rather
# than listed, so adding one stays a one-file change; mirrors sharedMigration
# Scripts in cmd/rkit/assemble.go.
#
# TEST SUITES ARE NOT PAYLOAD. The glob ships whatever is in the directory, and
# a suite written beside its subject put 25 KB of test harness, chmod 0755, into
# every edge, cli and relay zip. Suites belong in tools/<name>.test.sh — which
# is where every other shell suite in this repo lives, and where the one that
# got in has been moved to — and this exclusion is the second lock on that
# door: a *.test.sh or *_test.sh under inner/_shared/migrations is never staged.
# cmd/rkit/assemble.go's sharedMigrationScripts drops the same two patterns, and
# cmd/rkit/payload_manifest_test.go compares the two lists name-for-name.
shared_migration_scripts() {
    local p
    for p in "${SHARED_MIGRATIONS_DIR}"/*.sh; do
        [ -f "${p}" ] || continue
        case "$(basename "${p}")" in
            *.test.sh | *_test.sh) continue ;;
        esac
        printf '%s\n' "$(basename "${p}")"
    done | sort
}

# component_migration_files <src-dir> — the component's OWN half of its ladder,
# one basename per line, sorted: component.conf, ledger, and any rung the
# component authored for itself. Mirrors componentMigrationFiles in
# cmd/rkit/assemble.go.
component_migration_files() {
    local p
    for p in "$1"/migrations/*; do
        [ -f "${p}" ] || continue
        printf '%s\n' "$(basename "${p}")"
    done | sort
}

# takes_shared_ladder <comp> — whether this component's migrations/ is assembled
# from inner/_shared plus its own repo, rather than wholly from its own repo.
#
# relay joined for its 0.2.2 root-only collapse: its repo contributes
# component.conf, ledger and adopt_unit_home_tree.sh (the unit-derived source
# selection), and everything else — the runner, the sweep, the shared adoption
# rung its own rung delegates to — is staged from inner/_shared exactly as for
# edge and cli.
takes_shared_ladder() {
    case "$1" in
        edge|cli|relay) return 0 ;;
        *) return 1 ;;
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
            for p in "${src}"/migrations/*; do
                [ -f "${p}" ] || continue
                printf 'migrations/%s\n' "$(basename "${p}")"
            done
            ;;
        edge)
            printf '%s\n' covers/admin.html covers/default.html
            ;;
    esac
    # The SHARED ladder's members, for the components assembled from two
    # sources. Emitted after the per-component block above and in the same
    # order stage_component_migrations copies them — shared first, then the
    # component's own — because cmd/rkit/payload_manifest_test.go compares this
    # list name-for-name against extraPayload's, and an order that differed
    # would be a red test rather than a real defect.
    if takes_shared_ladder "${comp}"; then
        for s in $(shared_migration_scripts); do
            printf 'migrations/%s\n' "${s}"
        done
        for s in $(component_migration_files "${src}"); do
            printf 'migrations/%s\n' "${s}"
        done
    fi
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
    stage_component_migrations gateway "$1" "$2"
}

# stage_component_migrations <comp> <src-dir> <assemble-dir> — copy this
# component's whole migrations/ tree into the staged payload dir.
#
# TWO SHAPES, one function. The gateway's ladder is wholly its own: every file
# comes from its source worktree. edge's and cli's are assembled from two
# sources — the shared runner + library + rungs from inner/_shared/migrations,
# and the component's own component.conf + ledger (+ any rung it authored) from
# its source worktree. Keeping both shapes here rather than in two functions is
# what stops the second one from quietly missing a check the first one has: an
# empty result is a hard error either way, because shipping a component whose
# install.sh invokes a ladder that is not in the zip is exactly the defect this
# file exists to prevent.
stage_component_migrations() {
    local comp="$1" src="$2" dest="$3" p base found=0
    mkdir -p "${dest}/migrations"
    if takes_shared_ladder "${comp}"; then
        for base in $(shared_migration_scripts); do
            cp "${SHARED_MIGRATIONS_DIR}/${base}" "${dest}/migrations/${base}"
            chmod 0755 "${dest}/migrations/${base}"
            found=1
        done
        if [ "${found}" != 1 ]; then
            echo "✗ shared migrations missing: ${SHARED_MIGRATIONS_DIR}" >&2
            return 1
        fi
        # The component's own half. component.conf and ledger are REQUIRED: the
        # shared runner carries no component defaults and refuses without them,
        # so a kit missing either is a component whose every install ends in a
        # refusal — caught here, at the cut, rather than on a host.
        found=0
        for base in $(component_migration_files "${src}"); do
            cp "${src}/migrations/${base}" "${dest}/migrations/${base}"
            case "${base}" in *.sh) chmod 0755 "${dest}/migrations/${base}" ;; esac
            found=1
        done
        for base in component.conf ledger; do
            if [ ! -f "${dest}/migrations/${base}" ]; then
                echo "✗ ${comp} migrations/${base} missing in source: ${src}/migrations/${base}" >&2
                echo "  the shared runner has no component defaults — without it every install" >&2
                echo "  of this release refuses before it can migrate anything." >&2
                return 1
            fi
        done
        return 0
    fi
    for p in "${src}"/migrations/*; do
        [ -f "${p}" ] || continue
        base="$(basename "${p}")"
        cp "${p}" "${dest}/migrations/${base}"
        case "${base}" in *.sh) chmod 0755 "${dest}/migrations/${base}" ;; esac
        found=1
    done
    if [ "${found}" != 1 ]; then
        echo "✗ ${comp} migrations missing in source: ${src}/migrations" >&2
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
#     0.2.0 v0_1_to_v0_2.sh
#     "
#
# Word-split into (version, script) pairs exactly as the runner splits it, so
# the two cannot disagree about what the ledger says. Only an assignment at
# column 0 counts — that is where the runner writes it and where a commented-out
# copy never is. Mirrors ledgerMigrations in cmd/rkit/assemble.go.
# ledger_migrations <run.sh> — the migration script names the GATEWAY runner's
# MIGRATIONS= ledger declares, in ledger order, one per line.
#
# Only the gateway's runner keeps its ledger inside itself. The shared runner
# reads a migrations/ledger data FILE instead, because one runner is copied
# byte-identical into several kits and a per-component list cannot live inside
# it; ledger_file_migrations below reads that shape.
#
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
# ledger_file_migrations <ledger> — the script names a migrations/ledger data
# file declares, in ledger order, one per line.
#
# The file is "<version-this-upgrades-to> <script>" rows with `#` comments,
# word-split into pairs EXACTLY as the shared runner splits it, so the two
# cannot disagree about what a ledger says. An odd word count is an error rather
# than a truncation: a dangling word means a row has a target and no script (or
# the reverse), and the runner refuses on it, so a cut that shipped one would
# refuse on every host.
ledger_file_migrations() {
    awk '
        { sub(/#.*$/, ""); for (i = 1; i <= NF; i++) word[++c] = $i }
        END {
            if (c == 0 || c % 2 != 0) {
                print "ledger holds " c+0 " words, want (version, script) pairs" > "/dev/stderr"
                exit 1
            }
            for (i = 2; i <= c; i += 2) print word[i]
        }
    ' "$1"
}

# assert_updater_ledger <comp> <src-dir> <zip> <members> — the UPDATER track's
# own ledger, migrations/updater-ledger: a second, separate invocation of the
# same shared run.sh that walks migrations/ledger, created per component by
# Task 10 (edge, gateway, relay — cli and agent have no updater and are never
# checked here). First row: adopt_updater_unit.sh.
#
# OPTIONAL TODAY, CHECKED THE MOMENT ONE EXISTS: no component in this repo's
# own fixtures ships one yet, so a source tree without migrations/updater-ledger
# is not an error — nothing here names it. The moment a component's source DOES
# carry one, the same reasoning as the serve ledger applies verbatim: a row
# naming a script the zip does not carry is a rung run.sh refuses on, on every
# host, after the cut — and a release that cannot migrate must not be signed.
assert_updater_ledger() {
    local comp="$1" src="$2" zip_path="$3" members="$4"
    case "${comp}" in edge|gateway|relay) ;; *) return 0 ;; esac

    local ledger="${src}/migrations/updater-ledger"
    [ -f "${ledger}" ] || return 0

    if ! printf '%s\n' "${members}" | grep -qxF 'migrations/updater-ledger'; then
        echo "✗ ${comp} payload has no migrations/updater-ledger: ${zip_path}" >&2
        echo "  ${ledger} exists in source but was not staged into the zip; the updater" >&2
        echo "  track's ladder invocation would refuse on every host." >&2
        return 1
    fi

    local named name
    if ! named="$(ledger_file_migrations "${ledger}")"; then
        echo "✗ unparseable ${comp} updater ledger in ${ledger}" >&2
        return 1
    fi
    # shellcheck disable=SC2086  # ${named} is an intentional newline-list of script names; word-splitting is the point.
    for name in ${named}; do
        if ! printf '%s\n' "${members}" | grep -qxF "migrations/${name}"; then
            echo "✗ ${comp} updater migration \"${name}\" is named in the ledger of ${ledger} but is not in ${zip_path}" >&2
            return 1
        fi
    done
}

assert_payload_migrations() {
    local comp="$1" zip_path="$2" src="$3"
    case "${comp}" in gateway|edge|cli|relay) ;; *) return 0 ;; esac

    if ! command -v unzip >/dev/null 2>&1; then
        echo "✗ unzip not found — cannot verify the gateway payload carries migrations/" >&2
        return 1
    fi
    local members
    if ! members="$(unzip -Z1 "${zip_path}")"; then
        echo "✗ cannot list gateway payload: ${zip_path}" >&2
        return 1
    fi

    # THE SHARED-LADDER COMPONENTS ARE GATED ON THEIR OWN SHAPE. Their runner is
    # useless without lib_paths.sh (home resolution) and component.conf (the
    # component's name, tree and binary list), and their install.sh SOURCES
    # lib_stale_user_bins.sh for its own sweep. A zip missing any of them
    # installs cleanly and silently stops migrating or sweeping — which is
    # precisely the class of defect the gateway's gate below already exists for.
    if takes_shared_ladder "${comp}"; then
        local want wants ledger
        wants="run.sh upgrade.sh lib_paths.sh lib_stale_user_bins.sh component.conf ledger"
        # relay's own rung (adopt_unit_home_tree.sh, ledger-named and so covered
        # by the ledger check below) derives the adoption SOURCE and then
        # DELEGATES to the shared adopt_user_tree.sh — a dependency no ledger
        # row names, exactly like the sweep library one level up. A relay kit
        # without it refuses on every pre-collapse host, after the cut.
        [ "${comp}" = relay ] && wants="${wants} adopt_user_tree.sh"
        for want in ${wants}; do
            if ! printf '%s\n' "${members}" | grep -qxF "migrations/${want}"; then
                echo "✗ ${comp} payload has no migrations/${want}: ${zip_path}" >&2
                echo "  install.sh runs the ladder out of the unzipped bundle and sources the sweep" >&2
                echo "  from the same directory; without every one of these it installs cleanly and" >&2
                echo "  silently stops migrating. upgrade.sh is in the list because the HOSTED" >&2
                echo "  release.burrowee.com/${comp}/upgrade.sh one-liner execs it out of this same" >&2
                echo "  kit and refuses at runtime when it is absent." >&2
                return 1
            fi
        done
        ledger="${src}/migrations/ledger"
        if [ ! -f "${ledger}" ]; then
            echo "✗ ${comp} migration ledger missing in source: ${ledger}" >&2
            return 1
        fi
        local named name
        if ! named="$(ledger_file_migrations "${ledger}")"; then
            echo "✗ unparseable ${comp} migration ledger in ${ledger}" >&2
            return 1
        fi
        # shellcheck disable=SC2086  # ${named} is an intentional newline-list of script names; word-splitting is the point.
        for name in ${named}; do
            if ! printf '%s\n' "${members}" | grep -qxF "migrations/${name}"; then
                echo "✗ ${comp} migration \"${name}\" is named in the ledger of ${ledger} but is not in ${zip_path}" >&2
                return 1
            fi
        done
        assert_updater_ledger "${comp}" "${src}" "${zip_path}" "${members}" || return 1
        return 0
    fi

    if ! printf '%s\n' "${members}" | grep -qxF 'migrations/run.sh'; then
        echo "✗ gateway payload has no migrations/run.sh: ${zip_path}" >&2
        echo "  install.sh and update.sh run the ladder out of the unzipped bundle; without" >&2
        echo "  the runner every upgrade skips its state migrations silently and the daemon" >&2
        echo "  comes back pointed at state that is no longer there." >&2
        return 1
    fi

    # install.sh SOURCES migrations/lib_stale_user_bins.sh — it is not merely a
    # rung's dependency, it is the installer's own sweep, and the gateway's
    # 0.2.0 ladder rung loads the same file. A zip carrying install.sh without
    # it installs cleanly and silently stops sweeping the per-user copies that
    # shadow /usr/local/bin on PATH, which is precisely the defect that made the
    # sweep a rung in the first place. Named explicitly rather than left to the
    # ledger check below: the library is deliberately NOT a ledger row, so
    # nothing else would ever ask for it.
    if ! printf '%s\n' "${members}" | grep -qxF 'migrations/lib_stale_user_bins.sh'; then
        echo "✗ gateway payload has no migrations/lib_stale_user_bins.sh: ${zip_path}" >&2
        echo "  install.sh sources it for its stale per-user binary sweep, and the 0.2.0" >&2
        echo "  ladder rung sources the same file. Without it both stop sweeping, quietly." >&2
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
    assert_updater_ledger "${comp}" "${src}" "${zip_path}" "${members}" || return 1
}

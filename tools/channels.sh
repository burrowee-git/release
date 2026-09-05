#!/bin/sh
# channels.sh — the per-channel install constants, as data sourced by
# tools/gen-bootstraps.sh (and by tools/test-bootstraps.sh, which asserts on
# them without any part of the generator running).
#
# THREE constants, and they are the whole of what separates a beta install from
# a stable one on the same host:
#
#   ROOT         the machine-owned tree the component installs into. bin/ is its
#                execution surface, etc/<comp> its config root, var/<comp> its
#                data root — the same three the Go side resolves through core's
#                system_root.
#   DISPATCHER   the operator-typed dispatcher binary bundled into the kit
#                (`burrowee` on stable, `burroweeb` on beta — built with
#                -X main.systemBinDir=<ROOT>/bin -X main.userPrefix=<DISPATCHER>-,
#                see tools/build.sh).
#   UNIT_PREFIX  the channel segment in the system unit names: empty on stable,
#                `beta` on beta, giving com.burrowee.beta.gateway /
#                burrowee-beta-gateway.service. The two spellings a unit name
#                actually takes are derived from it here (UNIT_DOT / UNIT_DASH)
#                rather than in the templates, so a template never has to know
#                which separator its platform uses.
#
# They are RENDER-TIME constants, substituted into the outer bootstrap and the
# inner installers exactly where the stable literal used to sit. That is what
# makes the stable render byte-identical to the file it replaces — which is the
# regression test this repo has for the whole change (tools/test-bootstraps.sh).
# A runtime variable would not: it would move the literal, and every stable
# installer in the world would be a new file for no behavioural reason.
#
# What a channel cannot express as a constant is expressed as a BLOCK instead:
# a template line that is exactly @STABLE_ONLY_BEGIN@ / @STABLE_ONLY_END@ (or
# the @BETA_ONLY_*@ pair) wraps lines the other channel drops entirely — see
# render_channel_blocks in tools/gen-bootstraps.sh. Dropping, not commenting
# out, is what keeps the stable render byte-identical: an inert comment would
# still be a new line in every stable installer in the world.
#
# The two things those blocks guard, and why each is a block rather than a
# constant:
#
#   the 0.2→0.3 migration ladder and the legacy per-user unit teardown are
#   STABLE-ONLY. Under the beta root they are not merely unnecessary, they are
#   destructive: a beta install has no 0.2 history of its own to climb, and the
#   per-user units the teardown removes belong to the STABLE install running
#   beside it.
#
#   The ladder is dropped WHOLE under beta — every rung, plus the version-gated
#   config seeds beside it (edge's migrate_config) and the forced pass in
#   upgrade.sh — never rung by rung. A rung's gate asks "has this host crossed
#   version X yet", and a root created at 0.3 by the installer itself answers
#   "no" to all of them, so a per-rung gate would run the entire ladder on a
#   host with nothing to migrate. Worse, the work those rungs do is reached
#   through component CLIs and per-user paths that resolve the STABLE roots, so
#   what they would converge is the other install.
#
#   the beta listener defaults (gateway console_port=16519, edge's stable+1
#   lan/tls listeners) are BETA-ONLY. Stable's defaults are the binaries' own
#   and are seeded by nothing; beta's exist so the two instances do not fight
#   over a port, and they are seeded if-absent so an operator value survives.

# channel_root <channel>
channel_root() {
    case "$1" in
        beta) printf '/usr/local/burrowee/beta' ;;
        *)    printf '/usr/local/burrowee' ;;
    esac
}

# channel_dispatcher <channel>
channel_dispatcher() {
    case "$1" in
        beta) printf 'burroweeb' ;;
        *)    printf 'burrowee' ;;
    esac
}

# channel_unit_prefix <channel> — the bare segment; empty on stable.
channel_unit_prefix() {
    case "$1" in
        beta) printf 'beta' ;;
        *)    printf '' ;;
    esac
}

# channel_unit_dot <channel> — launchd label segment, e.g. com.burrowee.<dot>gateway
channel_unit_dot() {
    _cud="$(channel_unit_prefix "$1")"
    [ -n "$_cud" ] && printf '%s.' "$_cud"
    return 0
}

# channel_unit_dash <channel> — systemd unit segment, e.g. burrowee-<dash>gateway.service
channel_unit_dash() {
    _cuh="$(channel_unit_prefix "$1")"
    [ -n "$_cuh" ] && printf '%s-' "$_cuh"
    return 0
}

# channel_unit_root_args <channel> — the flags the gateway system units pass to
# name their roots. Stable keeps the pair it has always written; beta names the
# root ONCE (gateway feature 04: --home takes the install root and derives the
# etc/var split from it), so a beta unit cannot half-move.
channel_unit_root_args() {
    case "$1" in
        beta) printf -- '--home %s/etc' "$(channel_root "$1")" ;;
        *)    printf -- '--config-dir $SYS_CONFIG_DIR --data-dir $SYS_DATA_DIR' ;;
    esac
}

# channel_unit_root_plist_args <channel> — the same flags, as launchd plist
# <string> elements. Two spellings of one fact, kept beside each other rather
# than in the two templates that would otherwise each carry half of it.
channel_unit_root_plist_args() {
    case "$1" in
        beta) printf -- '<string>--home</string><string>%s/etc</string>' "$(channel_root "$1")" ;;
        *)    printf -- '<string>--config-dir</string><string>$SYS_CONFIG_DIR</string><string>--data-dir</string><string>$SYS_DATA_DIR</string>' ;;
    esac
}

# channel_updater_home_args / channel_updater_home_plist_args <channel> — what
# the UPDATER unit adds after `run`. Empty on stable, where the agent's own
# defaulting already resolves the system pair; --home on beta, where that same
# defaulting resolves the STABLE pair and a unit without it would fetch, place
# and restart against the other channel's tree (gateway feature 04, RunForHome).
channel_updater_home_args() {
    case "$1" in
        beta) printf -- ' --home %s/etc' "$(channel_root "$1")" ;;
        *)    printf '' ;;
    esac
}

channel_updater_home_plist_args() {
    case "$1" in
        beta) printf -- '<string>--home</string><string>%s/etc</string>' "$(channel_root "$1")" ;;
        *)    printf '' ;;
    esac
}

# channel_file_prefix <channel> — the filename prefix a rendered artefact takes.
channel_file_prefix() {
    case "$1" in
        beta) printf 'beta.' ;;
        *)    printf '' ;;
    esac
}

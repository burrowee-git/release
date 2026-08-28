#!/usr/bin/env bash
# targets.test.sh — unit tests for tools/targets.sh.
#
# Exercises the platform table and its predicates directly. NO part of the
# release path runs: release.sh is never invoked, nothing is built, signed or
# published.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HERE}/targets.sh"

FAILED=0
ok()   { printf 'ok: %s\n' "$1"; }
fail() { printf '✗ %s\n' "$1" >&2; FAILED=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: want '$3', got '$2'"; fi; }

# ---- TARGETS ---------------------------------------------------------------
check "TARGETS carries five platforms" "${#TARGETS[@]}" 5

# The whole point of the table living in one file: the fifth platform is here
# and nowhere else. Losing it is how the first beta cut shipped four zips.
found_legacy=0
for triple in "${TARGETS[@]}"; do
    read -r t_os t_arch t_variant <<<"${triple}"
    [ "$(plat_of "${t_os}" "${t_arch}" "${t_variant}")" = "darwin-amd64-legacy" ] && found_legacy=1
done
check "TARGETS includes darwin-amd64-legacy" "${found_legacy}" 1

# ---- plat_of ---------------------------------------------------------------
check "plat_of stock omits the variant"  "$(plat_of darwin arm64 '')"       "darwin-arm64"
check "plat_of appends a variant"        "$(plat_of darwin amd64 legacy)"   "darwin-amd64-legacy"
check "plat_of with variant unset"       "$(plat_of linux amd64)"           "linux-amd64"

# ---- ships_target ----------------------------------------------------------
# relay is gated and never installed on a pre-2021 Mac, so it does not pay for
# a darwin build, an rcodesign pass and an Apple notary submission to produce a
# legacy zip nothing can ask for.
if ships_target relay legacy; then
    fail "relay must NOT ship the legacy variant"
else
    ok "relay does not ship the legacy variant"
fi

# Everything else must be unaffected — the guard sits in a loop every relay cut
# runs, so a predicate that over-matched would silently drop real platforms.
for comp in cli gateway edge agent relay; do
    for variant in '' ; do
        if ships_target "${comp}" "${variant}"; then
            ok "${comp} ships the stock variant"
        else
            fail "${comp} must ship the stock variant"
        fi
    done
done
for comp in cli gateway edge agent; do
    if ships_target "${comp}" legacy; then
        ok "${comp} ships the legacy variant"
    else
        fail "${comp} must ship the legacy variant"
    fi
done

# ---- the relay cut's effective platform set --------------------------------
# What do_release_relay's loops actually iterate, expressed as the plat strings.
relay_plats=""
for triple in "${TARGETS[@]}"; do
    read -r t_os t_arch t_variant <<<"${triple}"
    ships_target relay "${t_variant}" || continue
    relay_plats="${relay_plats}$(plat_of "${t_os}" "${t_arch}" "${t_variant}") "
done
check "relay builds exactly the four base platforms" \
    "${relay_plats}" "darwin-arm64 darwin-amd64 linux-arm64 linux-amd64 "

pub_plats=""
for triple in "${TARGETS[@]}"; do
    read -r t_os t_arch t_variant <<<"${triple}"
    ships_target gateway "${t_variant}" || continue
    pub_plats="${pub_plats}$(plat_of "${t_os}" "${t_arch}" "${t_variant}") "
done
check "a public component still builds all five" \
    "${pub_plats}" "darwin-arm64 darwin-amd64 darwin-amd64-legacy linux-arm64 linux-amd64 "

if [ "${FAILED}" = 0 ]; then
    printf '\nALL OK\n'
else
    printf '\nFAILED\n' >&2
fi
exit "${FAILED}"

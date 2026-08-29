#!/usr/bin/env bash
# dispatcher_src.test.sh — exercises tools/dispatcher_src.sh directly, with no
# part of the release path running. Same shape as tools/release_origin.test.sh.
#
# What these pin: a beta cut must not touch stable dispatcher state, and must
# not bundle the dispatcher built from main. Before this, all three of source,
# version file and stamp file were pinned to stable regardless of --channel, so
# dispatcher work on the beta branch never reached a beta build and a beta cut
# wrote versions/burrowee.stamp.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/tools/dispatcher_src.sh"
source "${ROOT}/tools/release_origin.sh"

pass=0; fail=0
check() { # check <name> <got> <want>
    if [ "$2" = "$3" ]; then echo "ok: $1"; pass=$((pass+1))
    else echo "FAIL: $1 — got '$2' want '$3'"; fail=$((fail+1)); fi
}

# ── stamp file follows the channel ───────────────────────────────────────────
CHANNEL=stable; check "stable: stamp file is versions/burrowee.stamp" \
    "$(disp_stamp_file /R)" "/R/versions/burrowee.stamp"
CHANNEL=beta;   check "beta: stamp file is versions/burrowee.beta.stamp" \
    "$(disp_stamp_file /R)" "/R/versions/burrowee.beta.stamp"
# unset CHANNEL must behave exactly as stable — release.sh defines it late, and
# resolve_disp_stamp used to run before that in at least one call path.
unset CHANNEL;  check "unset channel defaults to stable's stamp file" \
    "$(disp_stamp_file /R)" "/R/versions/burrowee.stamp"

# ── version file follows the channel ─────────────────────────────────────────
CHANNEL=stable; check "stable: numbers from versions/burrowee" "$(disp_version_rel)" "versions/burrowee"
CHANNEL=beta;   check "beta: numbers from versions/burrowee.beta" "$(disp_version_rel)" "versions/burrowee.beta"
unset CHANNEL;  check "unset channel defaults to stable's version file" "$(disp_version_rel)" "versions/burrowee"

# ── version.sh args ──────────────────────────────────────────────────────────
# Stable passes NOTHING, not "--channel stable": the stable invocation has to
# stay byte-identical to what it was, so this change cannot alter stable output.
CHANNEL=stable; check "stable: passes no --channel at all" "$(disp_channel_args)" ""
CHANNEL=beta;   check "beta: passes --channel beta" "$(disp_channel_args)" "--channel beta"
# disp_channel_args ends in a test that is FALSE under stable; without its
# explicit `return 0` the function would exit non-zero and kill a `set -e` cut.
CHANNEL=stable; disp_channel_args >/dev/null; check "stable: exit status is 0 under set -e" "$?" "0"

# ── the beta source is DERIVED, never configured ─────────────────────────────
# beta_worktree_for is release_origin.sh's, shared with every other component,
# so the dispatcher cannot drift onto a second definition of "the beta tree".
check "beta source derives from the registry main path" \
    "$(beta_worktree_for /R/burrowee/code/main)" "/R/burrowee/code/main/../beta"

echo
if [ "${fail}" -eq 0 ]; then echo "ALL OK (${pass} assertions)"; else echo "TESTS FAILED (${fail} of $((pass+fail)))"; exit 1; fi

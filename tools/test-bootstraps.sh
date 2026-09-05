#!/usr/bin/env bash
# test-bootstraps.sh — the channel render is correct, and the STABLE render did
# not move.
#
# THE FIRST ASSERTION IS THE POINT. Every installer this repo serves is
# generated, and the beta twins were made by threading three constants
# (@ROOT@ / @DISPATCHER@ / @UNIT_PREFIX@, tools/channels.sh) through the same
# templates the stable ones render from. A change to any of them can silently
# move what stable installs — onto a different root, under a different unit
# name, past a migration ladder it needed. So: render everything, and require
# every stable artefact to come back byte for byte identical to the committed
# file. `git diff` is the comparison, because the committed files ARE the
# published ones and being in step with the generator is the same fact.
#
# It also catches the reverse, and that is why it does not filter to stable:
# a beta twin edited by hand rather than by editing its template is a twin the
# next `tools/gen-bootstraps.sh` run silently reverts.
#
# Run it after gen-bootstraps.sh, and after any merge that brings in a newer
# versions/*.stamp (the baked version floors move with those — see
# gen-bootstraps.sh's header).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

fail() { echo "✗ $*" >&2; exit 1; }
pass() { echo "✓ $*"; }

# The suite must not judge a tree that already had edits in it: a dirty
# bootstrap would be reported as generator drift, and a dirty template would be
# reported as nothing at all.
dirty="$(git status --porcelain -- '*/install.sh' '*/upgrade.sh' '*/updater.install.sh' '*/preflight.sh' 'inner/**' || true)"
[ -z "${dirty}" ] || fail "working tree already carries generated-file changes — commit or stash them before running this:
${dirty}"

sh tools/gen-bootstraps.sh >/dev/null || fail "tools/gen-bootstraps.sh failed"

drift="$(git status --porcelain -- '*/install.sh' '*/upgrade.sh' '*/updater.install.sh' '*/preflight.sh' 'inner/**' || true)"
[ -z "${drift}" ] || fail "rendering changed committed files — the generator and the tree disagree:
${drift}
(if the change is intended, commit the regenerated files with the template change)"
pass "every rendered installer, stable and beta, is byte-identical to the committed one"

# ---- what the beta twin must carry -----------------------------------------
# Spelled against tools/channels.sh rather than against literals, so this test
# reads the same table the generator does and cannot pass by agreeing with
# itself about a value neither of them uses.
# shellcheck source=tools/channels.sh
. "${ROOT}/tools/channels.sh"
BETA_ROOT="$(channel_root beta)"
BETA_DISP="$(channel_dispatcher beta)"
BETA_UNIT="$(channel_unit_prefix beta)"

has() { grep -q -- "$2" "$1" || fail "$1 does not carry: $2"; }
hasnt() { grep -q -- "$2" "$1" && fail "$1 must not carry: $2"; return 0; }
# The -E pair, for the assertions that must match a STATEMENT and not the
# comments that discuss it — an installer this heavily commented has both.
hasnt_re() { grep -Eq -- "$2" "$1" && fail "$1 must not carry a line matching: $2"; return 0; }

for comp in gateway edge; do
    outer="${comp}/beta.install.sh"
    inner="inner/${comp}/beta.install.sh"
    [ -f "${outer}" ] || fail "missing ${outer} (is versions/${comp}.beta.stamp present?)"
    [ -f "${inner}" ] || fail "missing ${inner}"

    has "${outer}" "${BETA_ROOT}/bin"
    has "${inner}" "BIN_DIR:-${BETA_ROOT}/bin"
    has "${inner}" "/${BETA_DISP}\""
    has "${inner}" "burrowee-${BETA_UNIT}-${comp}"
    has "${inner}" "com.burrowee.${BETA_UNIT}.${comp}"

    # The ladder and the legacy teardown are the stable install's, and a beta
    # twin that still ran them would converge — or delete — the OTHER channel.
    hasnt_re "${inner}" '^[[:space:]]*migrate_from_legacy[[:space:]]*$'
    hasnt_re "${inner}" '^[[:space:]]*run_migration_ladder[[:space:]]*$'
    hasnt_re "${inner}" '^[[:space:]]*remove_legacy_user_units[[:space:]]*$'
    # migrate_config is dropped WHOLE under beta, not merely gated: its seeds
    # go through `burrowee-edge-cli config get|set`, which resolves the STABLE
    # config root, so on a FRESH beta install every version gate is crossed and
    # the writes land in the OTHER install's config file.
    hasnt_re "${inner}" '^[[:space:]]*migrate_config[[:space:]]'
    # Same defect, the gateway's copy: `db snapshot` picks its own source and,
    # with no home to resolve, picks the STABLE database — a snapshot of the
    # other install, recorded as this transaction's rollback point.
    hasnt_re "${inner}" 'burrowee-gateway-cli" db snapshot'

    # And the stable twin still has to be the file it always was.
    has "${comp}/install.sh" '/usr/local/burrowee/bin'
    hasnt "${comp}/install.sh" "${BETA_ROOT}"
    hasnt "inner/${comp}/install.sh" "${BETA_ROOT}"
    hasnt "inner/${comp}/install.sh" "${BETA_DISP}"
done
pass "beta twins carry the beta root, dispatcher and unit prefix; stable twins carry none of them"

# The two listener facts this feature exists to place. Both are seed-if-absent
# in the installer, so the value here is what a fresh side-by-side host gets.
has inner/gateway/beta.install.sh 'console_port=16519'
hasnt inner/gateway/install.sh 'console_port=16519'
for kv in '127.0.0.1:9449' '8449' '127.0.0.1:9444'; do
    has inner/edge/beta.install.sh "${kv}"
done
hasnt inner/edge/install.sh 'seed_beta_defaults'
pass "beta gateway seeds console_port=16519; beta edge seeds the stable+1 listeners"

# The beta units must name the beta root ONCE, and the beta UPDATER unit must
# name it at all: its agent defaults to the stable pair (gateway feature 04).
has inner/gateway/beta.install.sh "burrowee-gateway --no-open --home ${BETA_ROOT}/etc"
has inner/gateway/beta.install.sh "burrowee-gateway-updater run --home ${BETA_ROOT}/etc"
pass "beta gateway units name the beta root, updater included"

# The same for EDGE, and it is the fix for what feature 08 measured on the CI
# machine: with no --home, a beta-only edge install created
# /usr/local/burrowee/etc/edge/config carrying stable's lan_listen — a cross-
# channel write into a root nothing had installed into. Both units, both
# platforms: the launchd plist is a second spelling of the same fact and a beta
# host that got only one of them would run half-isolated.
has inner/edge/beta.install.sh "burrowee-edge run --home ${BETA_ROOT}/etc"
has inner/edge/beta.install.sh "burrowee-edge-updater run --home ${BETA_ROOT}/etc"
for _bin in burrowee-edge burrowee-edge-updater; do
    has inner/edge/beta.install.sh "<string>\$SYS_BIN_DIR/${_bin}</string><string>run</string><string>--home</string><string>${BETA_ROOT}/etc</string>"
done
# And the stable edge units still carry NO --home: the daemon's own defaulting
# resolves the stable pair, and a flag there would be a new line in every
# stable installer in the field.
hasnt inner/edge/install.sh "burrowee-edge run --home"
hasnt inner/edge/install.sh "burrowee-edge-updater run --home"
pass "beta edge units name the beta root on both platforms, updater included; stable edge names none"

# seed_beta_config must not depend on WHERE it is called from. Its two callers
# reach it by different routes — the fresh install has run ensure_system_tree
# itself, BURROWEE_UNITS_ONLY (`service install`, no bundle) gets it only from
# render_units — and when it depended on that, the units-only path wrote into a
# config root that did not exist: the seed failed, warned, and the beta gateway
# started on the binary's default console port, 16518, the stable one.
#
# Asserted on the FUNCTION, not on the call order, because the call order is not
# something a linear read of the file can decide (a call inside another
# function's body is not a call on this path) — while "the function creates its
# own root" is, and it is the property that actually makes the defect
# impossible.
sed -n '/^seed_beta_config() {/,/^}/p' inner/gateway/beta.install.sh > "${TMPDIR:-/tmp}/sbc.$$"
grep -q 'ensure_system_tree' "${TMPDIR:-/tmp}/sbc.$$" \
    || { rm -f "${TMPDIR:-/tmp}/sbc.$$"; fail "seed_beta_config does not create its own config root — a units-only run seeds nothing and the beta gateway falls back to the stable console port"; }
grep -q '16519' "${TMPDIR:-/tmp}/sbc.$$" \
    || { rm -f "${TMPDIR:-/tmp}/sbc.$$"; fail "seed_beta_config no longer writes 16519"; }
rm -f "${TMPDIR:-/tmp}/sbc.$$"
pass "seed_beta_config creates its own config root, so neither caller's ordering can silence it"

echo "PASS tools/test-bootstraps.sh"

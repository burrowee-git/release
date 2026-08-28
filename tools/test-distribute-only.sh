#!/usr/bin/env bash
# test-distribute-only.sh — prove `release.sh --distribute-only <comp> <stamp>
# --dry-run` runs ONLY the distribution stub over an already-staged
# dist/<stamp>/ (as `rkit build` would produce it), with ZERO real writes.
#
# What this covers:
#   DRY-RUN: exits 0, prints the intended github/bootstrap/marker actions
#     (each line prefixed "would:"), and performs no real side effect — no new
#     git tag, no new git commit, no "gh release create" text in the output
#     (proving `ghp` was never actually invoked).
#   MISSING-STAGE: a <stamp> with no dist/<stamp>/ directory fails clearly
#     (rather than silently proceeding).
#   REGRESSION GUARD: the flag is additive — bare `release.sh -h` still shows
#     usage (the general arg loop still requires WHAT for the old path).
#
# Mirrors tools/test-r2-fallback.sh's harness style: isolated tmp dir, fake
# component source worktree (no dependency on the real Burrowee/cli checkout),
# cleanup trap, `say`/`die` helpers.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# ---- tool paths (the Burrowee per-dir hook strips /opt/homebrew/bin) ---------
export PATH="/opt/homebrew/bin:${PATH}"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\n✗ DISTRIBUTE-ONLY TEST FAILED: %s\n' "$*" >&2; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/test-distribute-only-XXXXXX")"
cleanup() { rm -rf "${W}"; }
trap cleanup EXIT INT TERM

COMP=cli
STAMP="v0.1.53.2026.07.13.deadbeef"
STAGE="${REPO_ROOT}/dist/${STAMP}"

cleanup_stage() { rm -rf "${STAGE}"; }
trap 'cleanup_stage; cleanup' EXIT INT TERM

# ladder_zip <zip> <migration-member...> — a REAL zip whose migrations/ members
# satisfy assert_payload_migrations. distribute-only runs that gate over every
# staged zip (it did not assemble them — rkit did), so a text file posing as a
# zip stopped being an acceptable fixture the day the gate learned to look
# inside the archive.
ladder_zip() {
    _lz_zip="$1"; shift
    _lz_dir="${W}/zip-fixture"
    rm -rf "${_lz_dir}"; mkdir -p "${_lz_dir}/migrations"
    for _lz_m in "$@"; do printf '#!/bin/sh\n' > "${_lz_dir}/migrations/${_lz_m}"; done
    rm -f "${_lz_zip}"
    ( cd "${_lz_dir}" && zip -r -q "${_lz_zip}" migrations/ )
}

# The shared-ladder member set the gate requires of a cli kit, plus the rung the
# fake source's ledger names.
CLI_LADDER="run.sh upgrade.sh lib_paths.sh lib_stale_user_bins.sh component.conf ledger stale_user_bins.sh"

# ---- (1) stage a fake dist/<stamp>/ (as `rkit build` would produce it) --------
say "staging fake dist/${STAMP}/"
rm -rf "${STAGE}"
mkdir -p "${STAGE}"
# Deliberately four platforms, not five: this is now the SHORTFALL case
# assert_platform_coverage (tools/release.sh) exists to catch — exactly what
# an rkit-produced stage looks like today, since rkit build has not been
# taught darwin-amd64-legacy (see tools/RUNBOOK.md's rkit-gap note). Step
# (4b) below proves the undeclared shortfall is refused, by name; step (4c)
# proves a WRONGLY-declared shortfall (naming the wrong platform) is refused
# too; step (5)'s invocations declare the real gap expected via
# RELEASE_SH_EXPECT_MISSING="darwin-amd64-legacy" so the rest of this test
# can keep exercising the dry-run stub behavior unrelated to platform
# coverage.
for plat in darwin-arm64 darwin-amd64 linux-arm64 linux-amd64; do
    # shellcheck disable=SC2086  # ${CLI_LADDER} is an intentional space-list.
    ladder_zip "${STAGE}/burrowee-${COMP}-${plat}.zip" ${CLI_LADDER}
done
if command -v shasum >/dev/null 2>&1; then
    ( cd "${STAGE}" && shasum -a 256 burrowee-"${COMP}"-*.zip > SHA256SUMS.txt )
elif command -v sha256sum >/dev/null 2>&1; then
    ( cd "${STAGE}" && sha256sum burrowee-"${COMP}"-*.zip > SHA256SUMS.txt )
else
    die "need shasum or sha256sum"
fi
printf 'dummy minisig content\n' > "${STAGE}/SHA256SUMS.txt.minisig"
ls "${STAGE}/"

# ---- (2) fake component source worktree (isolate from the real one) ----------
# It carries a migrations/ledger because the payload gate cross-checks the
# SOURCE ledger's rows against the staged zips' members.
FAKE_SRC="${W}/srccli"
mkdir -p "${FAKE_SRC}/migrations"
printf '0.2.0 stale_user_bins.sh\n' > "${FAKE_SRC}/migrations/ledger"

# ---- (3) capture git state before, to assert it's untouched after -----------
# (status is captured too — but only to diff against, since this test may run
# against an already-dirty dev worktree; dist/ and the fake stamp dir are
# excluded since staging them is this test's own setup, not a side effect.)
BEFORE_HEAD="$(/usr/bin/git -C "${REPO_ROOT}" rev-parse HEAD)"
BEFORE_TAG_COUNT="$(/usr/bin/git -C "${REPO_ROOT}" tag -l "${COMP}/*" | wc -l | tr -d ' ')"
BEFORE_STATUS="$(/usr/bin/git -C "${REPO_ROOT}" status --porcelain -- . ':!dist')"

# ---- (4) MISSING-STAGE: a stamp with no staged dir fails clearly -------------
say "MISSING-STAGE: distribute-only on an unstaged stamp fails clearly"
set +e
missing_out="$(BURROWEE_SRC_CLI="${FAKE_SRC}" \
    bash "${REPO_ROOT}/tools/release.sh" --distribute-only "${COMP}" "no-such-stamp-xyz" --dry-run 2>&1)"
missing_rc=$?
set -e
[ "${missing_rc}" -ne 0 ] || die "MISSING-STAGE: expected non-zero exit, got 0"
case "${missing_out}" in
    *"staged dir missing"*) : ;;
    *) die "MISSING-STAGE: expected a clear 'staged dir missing' error; got: ${missing_out}" ;;
esac
printf '  OK: missing stage rejected with a clear error\n'

# ---- (4b) SHORTFALL: the same 4-platform stage, undeclared, is refused ------
# assert_platform_coverage (tools/release.sh) runs ahead of the dry-run stub,
# so even a rehearsal over this fixture's deliberately-short stage (see the
# staging comment above) fails loudly, by component and missing platform,
# unless RELEASE_SH_EXPECT_MISSING names the exact platform(s) expected
# absent. This is the exact silent-four-platforms-of-five failure mode the
# darwin-legacy fix wave closed: `rkit build` -> `release.sh
# --distribute-only` must not exit 0 looking complete while missing
# darwin-amd64-legacy.
say "SHORTFALL: undeclared 4-platform stage is refused, by name"
set +e
short_out="$(BURROWEE_SRC_CLI="${FAKE_SRC}" \
    bash "${REPO_ROOT}/tools/release.sh" --distribute-only "${COMP}" "${STAMP}" --dry-run 2>&1)"
short_rc=$?
set -e
[ "${short_rc}" -ne 0 ] || die "SHORTFALL: expected non-zero exit for an undeclared short stage, got 0. Output:\n${short_out}"
case "${short_out}" in
    *"missing but not declared: darwin-amd64-legacy"*) : ;;
    *) die "SHORTFALL: expected the missing platform (darwin-amd64-legacy) named. Output:\n${short_out}" ;;
esac
case "${short_out}" in
    *"${COMP}"*"does not match the declared expectation"*) : ;;
    *) die "SHORTFALL: expected the component named. Output:\n${short_out}" ;;
esac
printf '  OK: undeclared short stage refused, naming the component and the missing platform\n'

# ---- (4c) WRONGLY-DECLARED: naming the wrong platform is refused too --------
# The count-based first cut of this gate (a bare integer override)
# could not tell "the expected platform is missing" from "some OTHER platform
# is missing but the total still matches" — a wrong declaration that happened
# to have the right count would have passed silently. Prove the named-set
# design catches exactly that: declare linux-arm64 missing when the actually
# -missing platform is darwin-amd64-legacy. Must fail, naming BOTH the real
# gap (undeclared) and the wrong claim (declared but actually staged).
say "WRONGLY-DECLARED: RELEASE_SH_EXPECT_MISSING names the wrong platform — refused"
set +e
wrong_out="$(BURROWEE_SRC_CLI="${FAKE_SRC}" RELEASE_SH_EXPECT_MISSING="linux-arm64" \
    bash "${REPO_ROOT}/tools/release.sh" --distribute-only "${COMP}" "${STAMP}" --dry-run 2>&1)"
wrong_rc=$?
set -e
[ "${wrong_rc}" -ne 0 ] || die "WRONGLY-DECLARED: expected non-zero exit, got 0. Output:\n${wrong_out}"
case "${wrong_out}" in
    *"missing but not declared: darwin-amd64-legacy"*) : ;;
    *) die "WRONGLY-DECLARED: expected the real gap (darwin-amd64-legacy) named as undeclared. Output:\n${wrong_out}" ;;
esac
case "${wrong_out}" in
    *"declared missing but actually staged: linux-arm64"*) : ;;
    *) die "WRONGLY-DECLARED: expected the wrong claim (linux-arm64) named as stale. Output:\n${wrong_out}" ;;
esac
printf '  OK: a wrongly-declared shortfall is refused, naming both the real gap and the wrong claim\n'

# ---- (5) DRY-RUN: run --distribute-only against the staged dir ---------------
# RELEASE_SH_EXPECT_MISSING="darwin-amd64-legacy" declares this fixture's
# deliberate four-platform stage as expected (see the staging comment above
# and (4b)/(4c) just above) so the rest of this step can exercise the
# dry-run stub's OTHER behavior — the "would:" action lines, no-side-effects,
# no-ghp-dependency — without tripping the shortfall gate this test now also
# covers.
say "DRY-RUN: release.sh --distribute-only ${COMP} ${STAMP} --dry-run"
set +e
out="$(BURROWEE_SRC_CLI="${FAKE_SRC}" RELEASE_SH_EXPECT_MISSING="darwin-amd64-legacy" \
    bash "${REPO_ROOT}/tools/release.sh" --distribute-only "${COMP}" "${STAMP}" --dry-run 2>&1)"
rc=$?
set -e
printf '%s\n' "${out}"

[ "${rc}" -eq 0 ] || die "dry-run exited ${rc} (expected 0). Output:\n${out}"
printf '  OK: exit 0\n'

# (a) prints the intended actions, each prefixed "would:".
would_count="$(printf '%s\n' "${out}" | grep -c 'would:' || true)"
[ "${would_count}" -ge 3 ] || die "expected multiple 'would:' lines, got ${would_count}. Output:\n${out}"
printf '  OK: %s intended-action lines (would:)\n' "${would_count}"

case "${out}" in
    *"would:"*"register_staged"*)   : ;;
    *) die "missing would: register_staged line. Output:\n${out}" ;;
esac
case "${out}" in
    *"would:"*"gh release create"*) : ;;
    *) die "missing would: GitHub Release line. Output:\n${out}" ;;
esac
case "${out}" in
    *"would:"*"gen-bootstraps"*)    : ;;
    *) die "missing would: gen-bootstraps line. Output:\n${out}" ;;
esac
case "${out}" in
    *"would:"*"scp"*"install.sh"*) : ;;
    *) die "missing would: self-hosting scp line. Output:\n${out}" ;;
esac
case "${out}" in
    *"would:"*"marker commit"*)     : ;;
    *) die "missing would: marker commit line. Output:\n${out}" ;;
esac
printf '  OK: github/bootstrap/self-hosting-scp/marker actions all logged as intent\n'

# (b) NO real side effects.
case "${out}" in
    *"release create"*"--title"*) die "dry-run text suggests a real 'gh release create' ran" ;;
esac
printf '  OK: no real \x27gh release create\x27 invocation text\n'

AFTER_HEAD="$(/usr/bin/git -C "${REPO_ROOT}" rev-parse HEAD)"
[ "${BEFORE_HEAD}" = "${AFTER_HEAD}" ] || die "HEAD moved (${BEFORE_HEAD} -> ${AFTER_HEAD}) — dry-run must not commit"
printf '  OK: no new git commit (HEAD unchanged: %s)\n' "${AFTER_HEAD}"

AFTER_TAG_COUNT="$(/usr/bin/git -C "${REPO_ROOT}" tag -l "${COMP}/*" | wc -l | tr -d ' ')"
[ "${BEFORE_TAG_COUNT}" = "${AFTER_TAG_COUNT}" ] || die "tag count changed (${BEFORE_TAG_COUNT} -> ${AFTER_TAG_COUNT}) — dry-run must not tag"
/usr/bin/git -C "${REPO_ROOT}" rev-parse --verify -q "refs/tags/${COMP}/${STAMP}" >/dev/null \
    && die "tag ${COMP}/${STAMP} exists — dry-run must not create it"
printf '  OK: no new git tag (%s tags for %s, unchanged)\n' "${AFTER_TAG_COUNT}" "${COMP}"

# Working tree status outside dist/ is unchanged by the dry-run (no accidental
# writes into the release repo itself — the staged dist/<stamp>/ we created is
# this test's own setup and is excluded here).
AFTER_STATUS="$(/usr/bin/git -C "${REPO_ROOT}" status --porcelain -- . ':!dist')"
[ "${BEFORE_STATUS}" = "${AFTER_STATUS}" ] || die "working tree status changed outside dist/ after dry-run:\nbefore:\n${BEFORE_STATUS}\nafter:\n${AFTER_STATUS}"
printf '  OK: working tree status unchanged outside dist/ (no scp/ghp/local-file side effects)\n'

# (c) proves no dependency on ghp for the dry-run path: re-run with a bare
# system-only PATH (no ~/.claude/bin, where the ghp wrapper lives; no homebrew
# extras) — must still succeed identically, since the dry-run branch never
# calls gh_release_publish (the only place ghp is invoked).
say "DRY-RUN with a system-only PATH (no ~/.claude/bin ghp wrapper) — must still succeed"
SYSTEM_ONLY_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
set +e
out2="$(BURROWEE_SRC_CLI="${FAKE_SRC}" RELEASE_SH_EXPECT_MISSING="darwin-amd64-legacy" PATH="${SYSTEM_ONLY_PATH}" \
    bash "${REPO_ROOT}/tools/release.sh" --distribute-only "${COMP}" "${STAMP}" --dry-run 2>&1)"
rc2=$?
set -e
[ "${rc2}" -eq 0 ] || die "dry-run on a system-only PATH exited ${rc2} (expected 0 — proves a real ghp/tooling dependency leaked into the dry-run branch). Output:\n${out2}"
printf '  OK: dry-run succeeds on a system-only PATH (no ghp wrapper reachable)\n'

# ---- (relay) private R2 distribute dry-run ----------------------------------
# relay takes the private path (distribute_relay): re-stage rkit's
# burrowee-relay-*.zip under latest.* names, re-sign, and (real) publish to R2 —
# no GitHub Release, no self-hosting scp. Dry-run must re-stage + log R2 intent
# with zero real writes.
say "relay private distribute --dry-run (R2 flow, no GitHub Release)"
RELAY_STAMP="v0.1.18.2026.07.14.deadbeef"
RELAY_STAGE="${REPO_ROOT}/dist/${RELAY_STAMP}"
cleanup_relay() { rm -rf "${RELAY_STAGE}"; }
trap 'cleanup_relay; cleanup_stage; cleanup' EXIT INT TERM
rm -rf "${RELAY_STAGE}"; mkdir -p "${RELAY_STAGE}"
# relay kits carry the shared ladder too (0.2.2 root-only collapse) — including
# adopt_user_tree.sh, the shared rung relay's own ledger-named rung delegates
# to — and distribute_relay gates every staged zip on it before re-staging.
RELAY_LADDER="${CLI_LADDER} adopt_user_tree.sh adopt_unit_home_tree.sh"
for plat in darwin-arm64 darwin-amd64 linux-arm64 linux-amd64; do
    # shellcheck disable=SC2086  # ${RELAY_LADDER} is an intentional space-list.
    ladder_zip "${RELAY_STAGE}/burrowee-relay-${plat}.zip" ${RELAY_LADDER}
done
# fake relay source worktree, ledger matching the staged rungs (the real relay
# main worktree may not carry a migrations/ dir until workstream A lands, and a
# harness must not depend on a sibling checkout's branch state anyway).
FAKE_RELAY_SRC="${W}/srcrelay"
mkdir -p "${FAKE_RELAY_SRC}/migrations"
printf '0.2.2 stale_user_bins.sh\n0.2.2 adopt_unit_home_tree.sh\n' > "${FAKE_RELAY_SRC}/migrations/ledger"
# ephemeral password-less minisign key (test.key is gitignored; pass via SIGN_KEY).
RELAY_KEY="${W}/relay-test.key"
minisign -W -G -f -p "${W}/relay-test.pub" -s "${RELAY_KEY}" >/dev/null 2>&1 || die "minisign keygen failed"
RELAY_BEFORE_HEAD="$(/usr/bin/git -C "${REPO_ROOT}" rev-parse HEAD)"
set +e
rout="$(SIGN_KEY="${RELAY_KEY}" BURROWEE_SRC_RELAY="${FAKE_RELAY_SRC}" \
    bash "${REPO_ROOT}/tools/release.sh" --distribute-only relay "${RELAY_STAMP}" --dry-run 2>&1)"
rrc=$?
set -e
[ "${rrc}" -eq 0 ] || die "relay dry-run exited ${rrc}. Output:\n${rout}"
case "${rout}" in *"latest.darwin-arm64.zip"*) ;; *) die "relay dry-run missing latest.* rename" ;; esac
case "${rout}" in *"would: publish-relay to R2 under relay/${RELAY_STAMP}/"*) ;; *) die "relay dry-run missing R2 publish intent" ;; esac
case "${rout}" in *"(private)"*) ;; *) die "relay dry-run missing (private) marker intent" ;; esac
case "${rout}" in *"no real writes"*) ;; *) die "relay dry-run missing no-writes confirmation" ;; esac
case "${rout}" in *"publish-relay --stamp"*) die "relay dry-run text suggests a real publish-relay ran" ;; esac
RELAY_AFTER_HEAD="$(/usr/bin/git -C "${REPO_ROOT}" rev-parse HEAD)"
[ "${RELAY_BEFORE_HEAD}" = "${RELAY_AFTER_HEAD}" ] || die "relay dry-run moved HEAD"
printf '  OK: relay dry-run — latest.* rename + R2 publish intent + (private) marker + no real writes\n'

# ---- (relay) incomplete ladder is refused at the gate -------------------------
# A staged relay kit whose migrations/ lost the shared adoption rung must fail
# distribute-only BEFORE anything is re-staged, re-signed or (would-be)
# uploaded — even on a rehearsal. This is the cut-time gate the 0.2.2 root-only
# collapse depends on: an incomplete ladder installs cleanly and refuses to
# adopt on every pre-collapse host.
say "relay incomplete-ladder staged kit is refused"
for plat in darwin-arm64 darwin-amd64 linux-arm64 linux-amd64; do
    # shellcheck disable=SC2086  # ${CLI_LADDER} is an intentional space-list.
    ladder_zip "${RELAY_STAGE}/burrowee-relay-${plat}.zip" ${CLI_LADDER} adopt_unit_home_tree.sh
done
set +e
gap_out="$(SIGN_KEY="${RELAY_KEY}" BURROWEE_SRC_RELAY="${FAKE_RELAY_SRC}" \
    bash "${REPO_ROOT}/tools/release.sh" --distribute-only relay "${RELAY_STAMP}" --dry-run 2>&1)"
gap_rc=$?
set -e
[ "${gap_rc}" -ne 0 ] || die "relay dry-run accepted a kit with no adopt_user_tree.sh. Output:\n${gap_out}"
case "${gap_out}" in
    *"adopt_user_tree.sh"*) : ;;
    *) die "relay incomplete-ladder refusal does not name the missing member. Output:\n${gap_out}" ;;
esac
cleanup_relay
printf '  OK: relay staged kit missing the shared adoption rung is refused, by name\n'

# ---- --distribute-only refuses --channel beta ---------------------------------
# A beta cut uploads to R2 in one step (release.sh's do_release CHANNEL=beta
# branch) — it never creates a GitHub Release or a staged dist/<stamp>/ for
# `rkit build` to hand off, so --distribute-only (which re-publishes exactly
# that kind of already-staged, already-released component) is meaningless for
# beta and must be refused BEFORE anything else runs — no dist/<stamp>/ needed
# for this fixture, since the refusal fires at arg-parse, ahead of the
# staged-dir check.
say "--distribute-only refuses --channel beta"
set +e
beta_out="$(bash "${REPO_ROOT}/tools/release.sh" --distribute-only "${COMP}" "${STAMP}" --channel beta --dry-run 2>&1)"
beta_rc=$?
set -e
[ "${beta_rc}" -eq 2 ] || die "--distribute-only --channel beta exited ${beta_rc} (expected 2). Output:\n${beta_out}"
case "${beta_out}" in
    *"--distribute-only is a stable-channel verb; a beta cut uploads to R2 in one step"*) : ;;
    *) die "--distribute-only --channel beta refusal text missing or changed. Output:\n${beta_out}" ;;
esac
printf '  OK: --distribute-only cli <stamp> --channel beta exits 2 with the stable-channel-verb refusal\n'

printf '\n  DISTRIBUTE-ONLY TEST PASSED (missing-stage + platform-shortfall-gate + wrong-declaration-gate + dry-run stub + no-side-effects + no-tool-dependency + relay-private + relay-ladder-gate + beta-refused)\n'

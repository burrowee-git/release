#!/usr/bin/env bash
# test-produce-then-distribute.sh — the two halves of a real release cut, run
# IN SEQUENCE, against a throwaway release-repo clone: `rkit build` (produce)
# stages a version bump, then `assert_cut_origin` (distribute's guard) is
# asked whether it may proceed. Each half had its own passing tests before
# this effort; nothing exercised the SEQUENCE, which is exactly how the
# deadlock shipped — the produce half leaves the tree in precisely the state
# the distribute half's guard used to refuse.
#
# Why this cannot go through `release.sh --distribute-only --dry-run`:
# --dry-run sets CUT_ORIGIN_MODE=report (release.sh), and assert_cut_origin
# returns 0 unconditionally in report mode (cut_origin.sh) — a real finding
# only prints a "⚠" warning. tools/test-distribute-only.sh drives exactly
# that path, so no assertion it could ever carry would go red on this. Every
# assert_cut_origin call below passes mode=strict for that reason.
#
# What's real vs. fixture: STEP ONE runs the actual `rkit build` binary,
# built from this worktree, against a real git clone and a real (if minimal)
# Go module — the produce half is not simulated. STEP TWO sources the real,
# unmodified tools/cut_origin.sh and calls assert_cut_origin directly (the
# same function release.sh's --distribute-only dispatch calls) against the
# tree STEP ONE actually left behind — the input to the guard is measured,
# not asserted to be a certain shape.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# ---- tool paths (the Burrowee per-dir hook strips /opt/homebrew/bin) ---------
export PATH="/opt/homebrew/bin:${PATH}"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\n✗ PRODUCE-THEN-DISTRIBUTE TEST FAILED: %s\n' "$*" >&2; exit 1; }

command -v minisign >/dev/null 2>&1 || die "minisign not found on PATH — required to sign the fixture build"
command -v zip       >/dev/null 2>&1 || die "zip not found on PATH — required to assemble the fixture build"

W="$(mktemp -d "${TMPDIR:-/tmp}/test-produce-then-distribute-XXXXXX")"
cleanup() { rm -rf "${W}"; }
trap cleanup EXIT INT TERM

export GIT_CONFIG_GLOBAL="${W}/gitconfig"   # keep the operator's identity/hooks out of it
/usr/bin/git config --file "${GIT_CONFIG_GLOBAL}" user.name  "Produce Then Distribute Test"
/usr/bin/git config --file "${GIT_CONFIG_GLOBAL}" user.email "produce-then-distribute@test.invalid"
/usr/bin/git config --file "${GIT_CONFIG_GLOBAL}" init.defaultBranch main

# shellcheck source=/dev/null
source "${REPO_ROOT}/tools/cut_origin.sh"

# ---- (1) build rkit from the worktree ----------------------------------------
say "building rkit from the worktree"
/opt/homebrew/bin/go build -o "${W}/rkit" ./cmd/rkit || die "go build ./cmd/rkit failed"

# ---- (2) bare origin + clone, populated as a minimal release repo -----------
# Same shape as cut_origin.test.sh's new_origin_and_clone (bare + clone, on
# main, HEAD pushed), but the seed commit IS the minimal release repo rather
# than a throwaway README, since the fixture's post-build state is what this
# test measures.
say "creating a throwaway release-repo origin + clone"
BARE="${W}/release.git"
CLONE="${W}/release"
/usr/bin/git init --quiet --bare "${BARE}"
/usr/bin/git clone --quiet "${BARE}" "${CLONE}" 2>/dev/null

mkdir -p "${CLONE}/versions" "${CLONE}/inner/cli" "${CLONE}/tools/testkeys"
printf '0.1.0\n' > "${CLONE}/versions/cli"
printf 'placeholder\n' > "${CLONE}/versions/cli.stamp"   # pre-existing and TRACKED, so the
                                                          # real build's rewrite lands as a
                                                          # staged MODIFY, not an ADD — the
                                                          # actual shape a second cut sees,
                                                          # not just a first one.
printf '0.1.0\n' > "${CLONE}/versions/burrowee"           # orchestrate's dispatcher stamp reads this
printf '#!/bin/sh\necho fixture-install\n' > "${CLONE}/inner/cli/install.sh"
cp "${REPO_ROOT}/tools/version.sh" "${CLONE}/tools/version.sh"
printf '/dist/\n' > "${CLONE}/.gitignore"   # rkit build writes dist/<stamp>/ into the release
                                             # repo (by design); ungitignored it would add an
                                             # untracked line to every status check below and
                                             # the "exactly two staged paths" assertion would
                                             # never be exact.

# Password-less test minisign key, generated fresh for this throwaway fixture
# and committed into the throwaway clone only — never pushed anywhere real,
# never the repo's own tools/testkeys/test.key. The public half is written
# outside the clone since nothing here needs it.
minisign -W -G -f -p "${W}/test.pub" -s "${CLONE}/tools/testkeys/test.key" >/dev/null 2>&1 \
    || die "minisign keygen failed"

/usr/bin/git -C "${CLONE}" add -A
/usr/bin/git -C "${CLONE}" commit --quiet -m "seed release repo"
/usr/bin/git -C "${CLONE}" push --quiet -u origin main

# ---- (3) throwaway component source (also serves as --dispatcher) ----------
# A trivial module: cmd/burrowee-cli + cmd/burrowee-cli-updater (relconfig.Bins
# for "cli"), a root package "." (relconfig.Bins for "burrowee", the
# dispatcher — this SAME tree is passed as both --src and --dispatcher, per
# the brief), and update.sh (extraPayload requires it for cli). git init +
# commit only — relconfig.Stamp needs a HEAD sha, never a push.
say "creating a throwaway component source (doubles as the dispatcher source)"
SRC="${W}/srccli"
mkdir -p "${SRC}/cmd/burrowee-cli" "${SRC}/cmd/burrowee-cli-updater"
cat > "${SRC}/go.mod" <<'EOF'
module fixture

go 1.25.0
EOF
MAIN_SRC='package main

import "fmt"

var version string

func main() { fmt.Println(version) }
'
printf '%s' "${MAIN_SRC}" > "${SRC}/cmd/burrowee-cli/main.go"
printf '%s' "${MAIN_SRC}" > "${SRC}/cmd/burrowee-cli-updater/main.go"
printf '%s' "${MAIN_SRC}" > "${SRC}/main.go"
printf '#!/bin/sh\necho fixture-update\n' > "${SRC}/update.sh"

/usr/bin/git -C "${SRC}" init --quiet
/usr/bin/git -C "${SRC}" add -A
/usr/bin/git -C "${SRC}" commit --quiet -m "seed component source"

# ── STEP ONE (produce), for real ─────────────────────────────────────────────
say "STEP ONE: rkit build --component cli --bump-patch (the real produce half)"
"${W}/rkit" build --component cli --repo "${CLONE}" --src "${SRC}" --dispatcher "${SRC}" \
    --bump-patch --no-vulncheck --sign-key "${CLONE}/tools/testkeys/test.key" \
    || die "rkit build failed"
printf '  OK: rkit build exited 0\n'

# rkit build is silent on success — assert the artifacts landed under the
# RELEASE repo's dist/<stamp>/, not merely that the command returned 0.
DIST_DIRS=("${CLONE}"/dist/*/)
[ "${#DIST_DIRS[@]}" -eq 1 ] || die "expected exactly one dist/<stamp>/ dir under ${CLONE}/dist, found ${#DIST_DIRS[@]}"
STAMP_DIR="${DIST_DIRS[0]}"
[ -f "${STAMP_DIR}SHA256SUMS.txt" ] || die "missing SHA256SUMS.txt under ${STAMP_DIR}"
ZIP_COUNT="$(ls "${STAMP_DIR}"burrowee-cli-*.zip 2>/dev/null | wc -l | tr -d ' ')"
[ "${ZIP_COUNT}" -ge 1 ] || die "no burrowee-cli-*.zip under ${STAMP_DIR}"
printf '  OK: %s and %s zip(s) under %s\n' "SHA256SUMS.txt" "${ZIP_COUNT}" "${STAMP_DIR}"

# Assert the produce half's contract BY MEASUREMENT: what git status actually
# reports, not a restatement of what it is supposed to report. The expected
# path set is DERIVED from staged_tolerance_for — the exact function
# release.sh's --distribute-only dispatch calls to build its own tolerance
# list — rather than naming versions/cli and versions/cli.stamp a second time
# in this file; cut_origin.test.sh's case (h) already pins that function's
# exact output for a given component.
EXPECTED_ALLOWED=()
while IFS= read -r line; do
    [ -n "${line}" ] || continue
    EXPECTED_ALLOWED+=("${line}")
done <<EOF
$(staged_tolerance_for 1 cli)
EOF
[ "${#EXPECTED_ALLOWED[@]}" -eq 2 ] || die "staged_tolerance_for 1 cli did not yield exactly 2 paths: ${EXPECTED_ALLOWED[*]:-<empty>}"

ST="$(/usr/bin/git -C "${CLONE}" status --porcelain --untracked-files=all)"
printf 'git status --porcelain --untracked-files=all:\n%s\n' "${ST}"
ST_LINES="$(printf '%s\n' "${ST}" | grep -c . || true)"
[ "${ST_LINES}" -eq 2 ] || die "expected exactly 2 staged lines after rkit build, got ${ST_LINES}:\n${ST}"
case "${ST}" in
    *"M  ${EXPECTED_ALLOWED[0]}"$'\n'*|*"M  ${EXPECTED_ALLOWED[0]}") : ;;
    *) die "expected '${EXPECTED_ALLOWED[0]}' staged as a MODIFY (M ), got:\n${ST}" ;;
esac
case "${ST}" in
    *"M  ${EXPECTED_ALLOWED[1]}"$'\n'*|*"M  ${EXPECTED_ALLOWED[1]}") : ;;
    *) die "expected '${EXPECTED_ALLOWED[1]}' staged as a MODIFY (M ) — it was pre-committed as a placeholder precisely so the real bump lands as M, not A. Got:\n${ST}" ;;
esac
printf '  OK: exactly 2 staged lines, both M  — %s and %s\n' "${EXPECTED_ALLOWED[0]}" "${EXPECTED_ALLOWED[1]}"

# ── STEP TWO (distribute's guard), for real, in STRICT mode ─────────────────
# This is the assertion that is RED against pre-Task-3 code: the pre-fix
# assert_cut_origin (or any call with no tolerance) refuses this exact tree
# with "release repo source tree is dirty" — the deadlock. Never routed
# through --dry-run/report mode (see header) — mode is unconditionally strict.
say "STEP TWO: assert_cut_origin(strict) against the REAL post-build tree — must return 0"
out="$(assert_cut_origin "release repo" "${CLONE}" "${CLONE}" strict "${EXPECTED_ALLOWED[@]}" 2>&1)" && r=0 || r=1
[ "${r}" -eq 0 ] || die "assert_cut_origin(strict, with tolerance) refused the real post-build tree:\n${out}"
[ -z "${out}" ] || die "assert_cut_origin(strict, with tolerance) printed output on what should be a silent pass:\n${out}"
printf '  OK: assert_cut_origin returned 0 — the produce-then-distribute sequence does not deadlock\n'

# Falsifiability: the IDENTICAL tree, asserted with no tolerance at all, must
# still be refused — the default call shape (every OTHER assert_cut_origins
# call site) is unchanged. Confirms STEP TWO's pass above is exercising the
# tolerance wiring, not passing for an unrelated reason.
out2="$(assert_cut_origin "release repo" "${CLONE}" "${CLONE}" strict 2>&1)" && r2=0 || r2=1
[ "${r2}" -eq 1 ] || die "assert_cut_origin(strict, NO tolerance) unexpectedly returned 0 — the default must remain refused"
case "${out2}" in
    *"source tree is dirty"*) : ;;
    *) die "expected the no-tolerance refusal to be the dirty-tree message, got:\n${out2}" ;;
esac
printf '  OK: the same tree with no tolerance argument is still refused (default unchanged)\n'

# ── pin the provenance shape of the marker commit ────────────────────────────
# release.sh:870 commits with NO pathspec (git add -A already happened; rkit
# build itself staged the two version paths) — assert the marker commit
# names both, and that it is the ONLY commit ahead of origin/main: one
# produce-then-distribute cycle must cost exactly one commit, not two.
say "pinning the marker commit's provenance shape"
/usr/bin/git -C "${CLONE}" commit --quiet -m "[RELEASED: cli] test produce-then-distribute"
STAT="$(/usr/bin/git -C "${CLONE}" show --stat HEAD)"
case "${STAT}" in *"${EXPECTED_ALLOWED[0]}"*) : ;; *) die "marker commit --stat does not name ${EXPECTED_ALLOWED[0]}:\n${STAT}" ;; esac
case "${STAT}" in *"${EXPECTED_ALLOWED[1]}"*) : ;; *) die "marker commit --stat does not name ${EXPECTED_ALLOWED[1]}:\n${STAT}" ;; esac
AHEAD="$(/usr/bin/git -C "${CLONE}" rev-list --count origin/main..HEAD)"
[ "${AHEAD}" -eq 1 ] || die "expected exactly 1 commit ahead of origin/main after the marker commit, got ${AHEAD}"
printf '  OK: marker commit names both version paths; exactly 1 commit ahead of origin/main\n'

printf '\n  PRODUCE-THEN-DISTRIBUTE TEST PASSED (rkit build staged the bump for real; assert_cut_origin(strict) accepted it; no-tolerance default still refuses it; marker commit shape pinned)\n'

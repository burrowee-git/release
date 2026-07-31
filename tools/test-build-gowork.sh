#!/usr/bin/env bash
# test-build-gowork.sh — prove tools/build.sh builds every binary in MODULE
# mode (GOWORK=off), never in workspace mode.
#
# Why this test exists: build.sh used to default bin_gowork to the EMPTY string
# and pass it as `GOWORK="${bin_gowork}"`. GOWORK="" is indistinguishable from
# GOWORK being unset — go still walks up from the build dir and adopts any
# go.work it finds. Component worktrees carry a per-worktree go.work that `use`s
# LOCAL core/console checkouts, and it is gitignored, so release.sh's
# source-cleanliness check structurally cannot see it: a cut would silently ship
# unmerged sources against a pinned-tag go.mod, with nothing in the release
# output to show for it.
#
# The probe: a throwaway module whose go.work `use`s a directory that does NOT
# exist. In workspace mode `go build` fails on the missing use directory; with
# GOWORK=off the file is ignored entirely and the build succeeds. So:
#
#   pre-fix  (bin_gowork="")     -> go adopts go.work    -> build FAILS
#   post-fix (bin_gowork="off")  -> go ignores go.work   -> build SUCCEEDS
#
# Fully hermetic: no network, no product source tree, no release tooling, and
# the built binary is never executed. Cross-compiled to linux so the darwin
# codesign branch in build.sh is not taken.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GO_BIN="${GO_BIN:-go}"
command -v "${GO_BIN}" >/dev/null 2>&1 || GO_BIN=/opt/homebrew/bin/go
command -v "${GO_BIN}" >/dev/null 2>&1 || { echo "✗ go not found on PATH or /opt/homebrew/bin/go" >&2; exit 1; }

die() { printf '\n✗ GOWORK TEST FAILED: %s\n' "$*" >&2; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/test-build-gowork-XXXXXX")"
trap 'rm -rf "${W}"' EXIT INT TERM

# ---- throwaway component source ---------------------------------------------
# COMP=agent has the simplest build map (one binary, ./cmd/burrowee-agent).
SRC="${W}/src"
mkdir -p "${SRC}/cmd/burrowee-agent"
cat > "${SRC}/go.mod" <<'MOD'
module github.com/burrowee-git/agent

go 1.25.0
MOD
cat > "${SRC}/cmd/burrowee-agent/main.go" <<'MAIN'
package main

func main() {}
MAIN

# The trap: a go.work that only resolves in workspace mode, and does not
# resolve at all. If build.sh lets go discover it, the build cannot succeed.
cat > "${SRC}/go.work" <<'WORK'
go 1.25.0

use (
	.
	./this-directory-does-not-exist
)
WORK

# ---- the build must ignore the go.work --------------------------------------
OUT="${W}/out"
if ! COMP=agent SRC_DIR="${SRC}" TARGETOS=linux TARGETARCH=amd64 \
     STAMP="v0.0.0.2026.01.01.deadbeef" OUT_DIR="${OUT}" GO_BIN="${GO_BIN}" \
     bash "${REPO_ROOT}/tools/build.sh" > "${W}/build.log" 2>&1; then
    sed 's/^/    /' "${W}/build.log" >&2
    die "build.sh honoured the component worktree's go.work — release builds must run with GOWORK=off (a gitignored go.work can substitute local, unmerged sources for the pinned go.mod versions)"
fi
[ -f "${OUT}/burrowee-agent" ] || die "build.sh reported success but produced no binary at ${OUT}/burrowee-agent"

# ---- and the toolchain must agree there is no workspace ---------------------
# Direct confirmation of the property the build relies on, independent of
# build.sh: "" behaves as unset, only "off" disables discovery.
unset_seen="$( cd "${SRC}" && GOWORK="" "${GO_BIN}" env GOWORK )"
[ "${unset_seen}" != "off" ] \
    || die "GOWORK=\"\" reported 'off' — the premise of this test no longer holds; re-derive the assertion in build.sh"
off_seen="$( cd "${SRC}" && GOWORK=off "${GO_BIN}" env GOWORK )"
[ "${off_seen}" = "off" ] \
    || die "GOWORK=off reported '${off_seen}', want 'off'"

printf '\n  GOWORK TEST PASSED (build.sh builds in module mode; go.work ignored)\n'

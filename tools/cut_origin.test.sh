#!/usr/bin/env bash
# cut_origin.test.sh — unit tests for tools/cut_origin.sh.
#
# Exercises every predicate directly against throwaway repos under a temp dir.
# NO part of the release path runs: release.sh is never invoked, nothing is
# built, signed or published. "origin" is a local bare repo, so the fetch
# predicate is exercised for real without a network.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HERE}/cut_origin.sh"

fail=0
check() { # check <label> <got> <want>
    if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 — got '$2' want '$3'"; fail=1; fi
}
check_contains() { # check_contains <label> <haystack> <needle>
    case "$2" in
        *"$3"*) echo "ok: $1" ;;
        *) echo "FAIL: $1 — '$2' does not contain '$3'"; fail=1 ;;
    esac
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export GIT_CONFIG_GLOBAL="${WORK}/gitconfig"   # keep the operator's identity/hooks out of it
/usr/bin/git config --file "${GIT_CONFIG_GLOBAL}" user.name  "Cut Origin Test"
/usr/bin/git config --file "${GIT_CONFIG_GLOBAL}" user.email "cut-origin@test.invalid"
/usr/bin/git config --file "${GIT_CONFIG_GLOBAL}" init.defaultBranch main

# new_origin_and_clone <name> — a bare "origin" plus a clone with one commit on
# main, pushed. Prints the clone path.
new_origin_and_clone() {
    local bare="${WORK}/$1.git" clone="${WORK}/$1"
    /usr/bin/git init --quiet --bare "${bare}"
    /usr/bin/git clone --quiet "${bare}" "${clone}" 2>/dev/null
    echo "seed" > "${clone}/README.md"
    /usr/bin/git -C "${clone}" add README.md
    /usr/bin/git -C "${clone}" commit --quiet -m "seed"
    /usr/bin/git -C "${clone}" push --quiet -u origin main
    printf '%s' "${clone}"
}

# ── check 1: registry source ─────────────────────────────────────────────────
is_registry_source /a/b /a/b && r=0 || r=1
check "registry: identical paths pass" "${r}" "0"
is_registry_source /a/b/.worktrees/dev /a/b && r=0 || r=1
check "registry: a different path fails" "${r}" "1"

# ── check 2: primary worktree ────────────────────────────────────────────────
MAIN="$(new_origin_and_clone primary)"
/usr/bin/git -C "${MAIN}" worktree add --quiet -b feature "${MAIN}/../primary-feature" >/dev/null 2>&1
is_primary_worktree "${MAIN}" && r=0 || r=1
check "primary: the clone itself passes" "${r}" "0"
is_primary_worktree "${MAIN}/../primary-feature" && r=0 || r=1
check "primary: a linked worktree fails" "${r}" "1"
is_primary_worktree "${WORK}" && r=0 || r=1
check "primary: a non-repo fails" "${r}" "1"

# ── check 3: branch ──────────────────────────────────────────────────────────
check "branch: reports main" "$(worktree_branch "${MAIN}")" "main"
check "branch: reports a feature branch" "$(worktree_branch "${MAIN}/../primary-feature")" "feature"
worktree_branch "${WORK}" >/dev/null; r=$?
check "branch: a non-repo returns 1, not git's 128" "${r}" "1"

# ── check 4: clean tree ──────────────────────────────────────────────────────
tree_clean "${MAIN}" && r=0 || r=1
check "clean: a clean tree passes" "${r}" "0"
echo "edit" >> "${MAIN}/README.md"
tree_clean "${MAIN}" && r=0 || r=1
check "clean: a modified file fails" "${r}" "1"
/usr/bin/git -C "${MAIN}" checkout --quiet -- README.md
touch "${MAIN}/stray.txt"
tree_clean "${MAIN}" && r=0 || r=1
check "clean: an untracked file also fails" "${r}" "1"
rm -f "${MAIN}/stray.txt"

echo
if [ "${fail}" = 0 ]; then echo "ALL OK"; else echo "TESTS FAILED"; exit 1; fi

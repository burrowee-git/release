#!/bin/sh
# _shared/migrations/lib_paths.sh — resolving the two homes every burrowee
# installer, sweep and migration rung has to agree about. SOURCED, never
# executed; it defines functions and nothing else.
#
# NOT A RUNG. run.sh walks the LEDGER and this file is not in it.
#
# THE TWO HOMES, and why each needs a function rather than a variable:
#
#   operator_home  the account whose PER-USER tree a pre-0.2.0 install wrote
#                  to. This is NOT $HOME on the path that matters. The
#                  documented install is `curl … | sudo sh`, where $HOME is
#                  /root (Linux) or /var/root (macOS) — a tree no per-user
#                  install ever wrote to. A sweep aimed at $HOME finds nothing,
#                  reports success, and leaves every shadowing copy in place.
#                  That trap has already produced one outage here, so
#                  $SUDO_USER is consulted first and $HOME is the fallback.
#
#   root_home      root's REAL home, which differs by platform: /root on Linux,
#                  /var/root on macOS. /root on macOS sits on the sealed
#                  read-only system volume, so every mkdir under it fails —
#                  and it fails from inside `set -eu`, i.e. it aborts the
#                  caller rather than returning an error anyone reads.
#
# Every value is defaulted with ${X:-…} so a caller that already resolved one
# (inner/edge/install.sh resolves $ROOT_HOME long before it sources this) keeps
# its answer. Nothing here runs at source time except these assignments.

# LEGACY_HOME_PARENTS — where an account's home may live on a host with neither
# getent nor dscl (a slim container image). Same name and same default as the
# gateway repo's migrations/run.sh and the Go side's defaultLegacyScanRoots, so
# a host that overrides one overrides all of them.
LEGACY_HOME_PARENTS="${LEGACY_HOME_PARENTS:-${BURROWEE_LEGACY_HOME_PARENTS:-/Users /home}}"

# ---------------------------------------------------------------------------
# home_of_user <name> — that account's home directory on stdout, or empty and
# non-zero. getent is the portable answer on Linux, dscl on macOS, and the
# parent-directory guess is the last resort.
# ---------------------------------------------------------------------------
home_of_user() {
    _hu=""
    if command -v getent >/dev/null 2>&1; then
        _hu="$(getent passwd "$1" 2>/dev/null | cut -d: -f6)"
    fi
    if [ -z "$_hu" ] && command -v dscl >/dev/null 2>&1; then
        _hu="$(dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')"
    fi
    if [ -z "$_hu" ]; then
        for _hu_p in $LEGACY_HOME_PARENTS; do
            if [ -d "$_hu_p/$1" ]; then _hu="$_hu_p/$1"; break; fi
        done
    fi
    [ -n "$_hu" ] || return 1
    echo "$_hu"
}

# ---------------------------------------------------------------------------
# operator_home — the home of the account whose per-user tree the pre-0.2.0
# install actually wrote to.
#
# $SUDO_USER is who invoked sudo; it is unset for a genuine root login, where
# $HOME is already the right answer. `root` is treated as unset for the same
# reason — `sudo -u root` names no per-user tree this is about.
#
# It NOTES a $SUDO_USER whose home cannot be resolved instead of failing: the
# fallback to $HOME is a narrower answer than the caller asked for, and a
# narrowed scope that says nothing is the failure this whole file exists to
# stop being silent about.
# ---------------------------------------------------------------------------
operator_home() {
    case "${SUDO_USER:-}" in
    '' | root) ;;
    *)
        if _oh="$(home_of_user "$SUDO_USER")" && [ -n "$_oh" ]; then
            echo "$_oh"
            return 0
        fi
        echo "note: \$SUDO_USER='$SUDO_USER' has no resolvable home — falling back to \$HOME," >&2
        echo "note: which under sudo is root's and holds no per-user burrowee tree." >&2
        ;;
    esac
    echo "${HOME:-}"
}

# ---------------------------------------------------------------------------
# root_home — root's real home directory. $ROOT_HOME wins when the caller has
# already resolved it (inner/edge/install.sh has, and its Go test harness
# redirects it into a sandbox).
#
# Resolved from ~root rather than from $HOME because under `sudo sh` $HOME is
# not reliably root's — macOS sudo keeps the invoking user's by default. A
# tilde expansion that does not produce an absolute path (no such account, a
# shell that does not expand it) falls back to the platform's well-known value
# rather than to the literal string "~root", which would be created as a
# directory named "~root" in the cwd.
# ---------------------------------------------------------------------------
root_home() {
    if [ -n "${ROOT_HOME:-}" ]; then echo "$ROOT_HOME"; return 0; fi
    if [ "$(uname -s)" = "Darwin" ]; then
        _rh="$(eval echo ~root 2>/dev/null || true)"
        case "$_rh" in /*) ;; *) _rh=/var/root ;; esac
    else
        _rh=/root
    fi
    echo "$_rh"
}

#!/bin/sh
# Burrowee inner installer — agent (POSIX sh).
#
# Ships at the ROOT of the verified release zip as `install.sh`. The outer
# bootstrap verifies the zip (minisign + sha256) and ONLY THEN execs this with
# cwd = the unzipped dir, so the binaries sit alongside this script. It installs
# them into PREFIX/bin (default $HOME/.local/bin). Set BURROWEE_UNINSTALL to
# remove them instead.
set -eu

BIN_DIR="${PREFIX:-$HOME/.local}/bin"
BINS="burrowee burrowee-agent"
COMP=agent

if [ -n "${BURROWEE_UNINSTALL:-}" ]; then
    for b in $BINS; do rm -f "$BIN_DIR/$b"; done
    echo "removed from $BIN_DIR: $BINS"
    exit 0
fi

mkdir -p "$BIN_DIR"
for b in $BINS; do
    [ -f "./$b" ] || { echo "missing $b in archive" >&2; exit 1; }
    install -m 0755 "./$b" "$BIN_DIR/$b"
    if [ "$(uname -s)" = "Darwin" ]; then
        xattr -d com.apple.quarantine "$BIN_DIR/$b" 2>/dev/null || true
    fi
done
echo "installed to $BIN_DIR: $BINS"

"$BIN_DIR/burrowee" --version 2>/dev/null || true

# ---- first-run next step (fresh installs) -------------------------------------
# Re-install short-circuit: if this component already has persisted state under
# ~/.burrowee/agent (the bound identity + config) it is already set up. Unlike
# cli/gateway there is no setup blob to paste — binding is a one-touch web
# ceremony the operator drives — so print the next command instead of prompting.
COMP_HOME="$HOME/.burrowee/$COMP"
if [ -d "$COMP_HOME" ] && [ -n "$(ls -A "$COMP_HOME" 2>/dev/null || true)" ]; then
    echo "$COMP already set up ($COMP_HOME) — skipping setup."
else
    echo "next: burrowee-agent bootstrap   (new account; GitHub OAuth)"
    echo "  or: burrowee-agent bind        (bind to an existing account)"
fi

# ---------------------------------------------------------------------------
# render_path_advice <bin-dir> — the "Next steps" block every burrowee
# installer ends with: how to reach <bin-dir> from the operator's own shell, in
# that shell's syntax, naming the profile file that makes it permanent.
#
# IT IS VENDORED HERE, and that is a property of the KIT rather than a
# preference. Every other component sources this function out of
# migrations/lib_stale_user_bins.sh, inside the byte-pinned SHARED SWEEP
# CONTRACT region — but tools/payload.sh stages migrations/ only for the
# components takes_shared_ladder names (edge, cli, relay), and the agent is not
# one of them: it runs no ladder and its kit carries no migrations/ directory
# at all, so there is nothing beside this script to source. The copy is driven
# by inner/cli/install_test/path_advice_test.go so it cannot drift unnoticed.
#
# IT IS SMALLER THAN THE SHARED ONE, deliberately. This installer is
# UNPRIVILEGED — it writes into ${PREFIX:-$HOME/.local}/bin and is never run
# under `curl … | sudo sh` — so the process IS the operator and $SHELL/$HOME
# are exact. There is no passwd lookup because there is no elevation record to
# resolve: a run that somehow arrives with $SUDO_USER set, or at euid 0, has no
# subject this script can name and gets the generic block rather than a guess.
#
# IT REPLACED a one-line note ("$BIN_DIR is not on PATH — add: export PATH=…")
# wrapped in a `case ":$PATH:"` test. That note named no shell and no profile
# file, so an operator whose login shell is fish was handed a line that is a
# syntax error there.
#
# PRINTED, NEVER APPLIED: nothing here writes, sources or evals anything in the
# operator's shell.
# ---------------------------------------------------------------------------
render_path_advice() {
    _rpa_dir="$1"
    [ -n "$_rpa_dir" ] || return 0

    _rpa_shell=""
    _rpa_home=""
    case "${SUDO_USER:-}" in
    '' | root)
        if [ "$(id -u)" != 0 ]; then
            _rpa_shell="${SHELL:-}"
            _rpa_home="${HOME:-}"
        fi
        ;;
    esac

    _rpa_now="export PATH=\"$_rpa_dir:\$PATH\""
    _rpa_profile=""
    _rpa_permanent=""
    if [ -n "$_rpa_home" ]; then
        case "${_rpa_shell##*/}" in
        zsh)
            _rpa_profile="$_rpa_home/.zprofile"
            ;;
        bash)
            # A macOS login shell reads .bash_profile and never .profile; a
            # Linux one reads .profile. Naming the wrong one is advice that
            # silently does nothing at the next login.
            if [ "$(uname -s)" = "Darwin" ]; then
                _rpa_profile="$_rpa_home/.bash_profile"
            else
                _rpa_profile="$_rpa_home/.profile"
            fi
            ;;
        fish)
            _rpa_profile="$_rpa_home/.config/fish/config.fish"
            _rpa_now="set -gx PATH $_rpa_dir \$PATH"
            _rpa_permanent="fish_add_path $_rpa_dir"
            ;;
        esac
    fi
    if [ -n "$_rpa_profile" ] && [ -z "$_rpa_permanent" ]; then
        _rpa_permanent="echo '$_rpa_now' >> $_rpa_profile"
    fi

    echo ""
    echo "==> Next steps"
    echo "burrowee's commands are in $_rpa_dir, which is not on your PATH."
    echo ""
    echo "  Add it to this shell now:"
    echo "    $_rpa_now"
    echo ""
    if [ -n "$_rpa_profile" ]; then
        echo "  Make it permanent:"
        echo "    $_rpa_permanent"
        case "${_rpa_shell##*/}" in
        fish) echo "    (that records it for every fish session; $_rpa_profile works too)" ;;
        esac
    else
        echo "  Make it permanent by adding the line above to your shell's startup file."
    fi
    echo ""
    echo "  Then:  burrowee help"
    return 0
}

# ---- the last thing printed: how to reach these commands --------------------
# THE `case ":$PATH:"` GUARD IS BACK, and only here. The root installers print
# unconditionally because under `sudo` they see root's secure_path and cannot
# observe the operator's interactive PATH — the question is unanswerable there,
# so it must not be guessed. THIS installer runs UNPRIVILEGED: the process IS
# the operator's shell, $PATH is theirs, and the answer is exact. Printing "not
# on your PATH" at a directory that demonstrably is on it would be telling them
# something false, which is worse than saying nothing.
#
# So: silent when $BIN_DIR is already reachable, the full shell-aware block
# when it is not.
#
# Nothing else owns this any more either: the outer bootstrap's rc-editing
# block, which used to run after this script returned, is deleted — see
# tools/bootstrap.template.sh for the three reasons.
case ":$PATH:" in
*":$BIN_DIR:"*) ;;
*) render_path_advice "$BIN_DIR" ;;
esac

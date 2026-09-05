#!/bin/sh
# Burrowee inner installer — cli (POSIX sh).
#
# Ships at the ROOT of the verified release zip as `install.sh`. The outer
# bootstrap verifies the zip (minisign + sha256) and ONLY THEN execs this with
# cwd = the unzipped dir, so the binaries sit alongside this script. It installs
# them into PREFIX/bin (default $HOME/.local/bin). Set BURROWEE_UNINSTALL to
# remove them instead. Set BURROWEE_UNITS_ONLY=1 for the offline units-only
# reinstall (a no-op here — the cli lays no service unit).
#
# THE MIGRATION LADDER. Since 0.2.0 this kit carries migrations/ — a runner
# shared with edge (authored once in inner/_shared/migrations and staged into
# both kits by tools/payload.sh), the component's own ledger, and the rungs the
# ledger names. It is walked UNCONDITIONALLY on every install and is a no-op
# unless a rung applies, so there is no second copy of the gate here.
#
# WHY THE CLI HAS ONE AT ALL, given that its 0.2.0 rung is a no-op on an
# ordinary cli host. The rung removes per-user binaries that SHADOW $BIN_DIR on
# PATH, and on a default cli install those are the same directory — the library
# refuses to sweep its own destination, so nothing applies and the ladder says
# so. It has work only on a cli whose $BIN_DIR is elsewhere (an explicit
# PREFIX). The ladder is here for the same reason the gateway's is: it is the
# only path a state change can take to a host the installer is run on, the
# version anchor below is what gates it, and adding the first rung that matters
# must not also mean adding the machinery to run it.
#
# THE DISPATCHER IS NOT THE CLI'S TO REMOVE UNILATERALLY. `burrowee` is shared
# by every co-installed component; the rule the shared library implements is
# that it goes only when no OTHER file in that directory matching burrowee-*
# carries the github.com/burrowee-git/ build stamp. A co-installed
# burrowee-gateway pins it; an operator's own `burrowee-notes` script does not.
set -eu

BIN_DIR="${PREFIX:-$HOME/.local}/bin"
BINS="burrowee burrowee-cli burrowee-cli-updater"
COMP=cli
TREE_ROOT="$HOME/.burrowee"
COMP_HOME="$TREE_ROOT/$COMP"
SOCKET_DIR="$COMP_HOME/sockets"
# The ladder's version anchor. Nothing wrote one before this ladder existed, so
# there is no name in the field to keep compatibility with; migrations/run.sh
# reads it as $COMP_HOME/$VERSION_FILE and migrations/component.conf in the cli
# repo declares the same spelling.
VERSION_MARKER="$COMP_HOME/.installed-version"

# Units-only mode (BURROWEE_UNITS_ONLY=1): the offline reinstall entrypoint run
# by cli's LocalReinstall. The cli lays NO service unit, so there is nothing to
# render or reload — this is a successful no-op that places no binaries and does
# not touch the network.
if [ -n "${BURROWEE_UNITS_ONLY:-}" ]; then
    echo "cli units-only reinstall: no service unit to render — nothing to do."
    exit 0
fi

if [ -n "${BURROWEE_UNINSTALL:-}" ]; then
    for b in $BINS; do rm -f "$BIN_DIR/$b"; done
    echo "removed from $BIN_DIR: $BINS"
    exit 0
fi

# ---------------------------------------------------------------------------
# THE USER'S OWN TREE — created FIRST, and loudly.
#
# ~/.burrowee belongs to the account that runs this installer, and this
# installer is the ONLY thing that creates it (operator ruling 2026-09-05). No
# root-run component installer creates or repairs it any more, and nothing here
# ever chowns it: a tree an older root-run installer already took is the
# operator's to hand back by hand. `burrowee doctor` reports the same row and
# names the same remedy, and `doctor --fix` deliberately repairs a missing tree
# but never an owner.
#
# WHAT THIS REPLACES: three `mkdir -p "$COMP_HOME" 2>/dev/null || true` — one
# before the ladder, one before the version anchor, one before the self-copy.
# On a host whose ~/.burrowee a root-run gateway installer had taken, all three
# failed silently and the install still reported success; the first thing to
# say anything was `burrowee bootstrap`, long after the operator had been told
# the cli was installed. The tree is a PRECONDITION of the install, not a side
# effect of three later steps, so it is created once, before any binary is
# placed, and a failure stops with nothing half-done.
#
# It runs AFTER the units-only and uninstall branches above: neither places
# anything, and neither should leave a directory behind on a host that has none.
# ---------------------------------------------------------------------------

# The stat dialect, decided once. Same probe, and the same reason, as
# inner/gateway/install.sh: `stat` takes its format as `-c` on GNU and `-f` on
# BSD/macOS, and on GNU `-f` is --file-system — so `stat -f '%u' PATH` there
# does not fail cleanly. It reads '%u' as a second path, dumps PATH's
# filesystem geometry to stdout and exits 1, and a `-f … || -c …` chain hands
# the caller that dump concatenated with the real answer. That shipped once and
# stranded a node. Probe against a path that certainly exists, then only ever
# use the flag that was proved to work.
#
# is_digits is what makes a multi-line blob unmistakable: every newline and
# every word of a filesystem dump is a non-digit.
is_digits() {
    case "$1" in
    '' | *[!0-9]*) return 1 ;;
    esac
    return 0
}

STAT_FLAVOR=none
if is_digits "$(stat -c '%u' / 2>/dev/null)"; then
    STAT_FLAVOR=gnu
elif is_digits "$(stat -f '%u' / 2>/dev/null)"; then
    STAT_FLAVOR=bsd
fi

# stat_uid <path> — the owner's uid, or NOTHING and non-zero. There is no third
# outcome: a helper that can put junk on stdout turns the comparison below into
# a silent false, which reads to an operator as "your tree is wrong" rather
# than "I could not look".
stat_uid() {
    case "$STAT_FLAVOR" in
    gnu) _su_v="$(stat -c '%u' "$1" 2>/dev/null)" || return 1 ;;
    bsd) _su_v="$(stat -f '%u' "$1" 2>/dev/null)" || return 1 ;;
    *) return 1 ;;
    esac
    is_digits "$_su_v" || return 1
    printf '%s\n' "$_su_v"
}

# uid_label <uid> — "root (uid 0)" where the account has a name here, "uid 0"
# where it does not. A message names an account; it never fails to print one.
uid_label() {
    [ -n "$1" ] || { printf 'this account\n'; return 0; }
    _ul_name="$(id -un "$1" 2>/dev/null || true)"
    if [ -n "$_ul_name" ]; then
        printf '%s (uid %s)\n' "$_ul_name" "$1"
    else
        printf 'uid %s\n' "$1"
    fi
}

# tree_is_mine <dir> — true when <dir> belongs to the account running this.
#
# The comparison is `stat`'s owner against `id -u` rather than the shell's own
# `[ -O ]` so that the REFUSAL is reachable from an unprivileged suite: no test
# can create a directory owned by somebody else, but it can put an `id` on PATH
# that reports a different uid (inner/cli/install_test/user_tree_test.go, and
# the gateway suite's fakeRootUID before it). `[ -O ]` reads the euid straight
# out of the process, where no test can reach it, and a refusal nothing
# exercises is a refusal that rots.
#
# `[ -O ]` is still the FALLBACK, for a host where `stat` speaks neither
# dialect or `id` is not there: an installer that cannot look must not answer
# "not yours" about a tree that is fine. A false refusal here removes the only
# path the operator has left.
tree_is_mine() {
    _tim_owner="$(stat_uid "$1" || true)"
    _tim_me="$(id -u 2>/dev/null || true)"
    if [ -z "$_tim_owner" ] || ! is_digits "$_tim_me"; then
        [ -O "$1" ]
        return
    fi
    [ "$_tim_owner" = "$_tim_me" ]
}

# refuse_foreign_tree <dir> <my-uid> — the loud half. Never returns.
#
# TWO MESSAGES, because the two directions have different remedies. Running as
# a user against a root-owned tree, the repair is the operator's chown and then
# this installer again. Running as ROOT against a human's tree — `sudo sh
# install.sh` — the repair is the invocation: advising `chown -R 0` on somebody's
# own directory would hand their tree to root, which is the defect this whole
# change exists to remove. `burrowee doctor --fix` grew the same pair of
# branches for the same reason.
refuse_foreign_tree() {
    _rf_dir="$1"
    _rf_me="$2"
    _rf_owner="$(stat_uid "$_rf_dir" || true)"
    if [ -n "$_rf_owner" ]; then
        _rf_who="$(uid_label "$_rf_owner")"
    else
        _rf_who="another account"
    fi
    echo "error: $_rf_dir is owned by $_rf_who, not by $(uid_label "$_rf_me")." >&2
    if [ "$_rf_me" = 0 ]; then
        echo "error: ~/.burrowee is the user's own tree and root does not create or repair it." >&2
        echo "error: Re-run this installer WITHOUT sudo, as $_rf_who." >&2
    else
        # The owner to chown TO, resolved to numbers so the line pastes into any
        # shell. Where this run could not learn its own uid the command is
        # printed with the substitutions left in: it still pastes, and it still
        # resolves to the account that runs it, which is the account that owns
        # the tree.
        if is_digits "$_rf_me"; then
            _rf_own="$_rf_me:$(id -g 2>/dev/null || printf '%s' "$_rf_me")"
        else
            _rf_own='$(id -u):$(id -g)'
        fi
        echo "error: This installer creates ~/.burrowee/$COMP itself and never changes the" >&2
        echo "error: ownership of a tree it does not own. Repair it by hand:" >&2
        echo "error:" >&2
        echo "error:     sudo chown -R $_rf_own $_rf_dir" >&2
        echo "error:" >&2
        echo "error: then re-run this installer. \`burrowee doctor\` reports the same tree." >&2
    fi
    echo "error: Nothing has been installed." >&2
    exit 1
}

# ensure_user_tree — $HOME/.burrowee, $COMP_HOME and $COMP_HOME/sockets, each
# created at 0700 if absent and each proved ours if present.
#
# EVERY LEVEL IS CHECKED, not just the root: the host this exists for has a
# root-owned ~/.burrowee, but one whose ~/.burrowee/cli alone was taken is the
# same defect one directory down, and the message has to name the directory
# that is actually wrong.
#
# The mode is set ON CREATION ONLY (`mkdir -m`, which the umask does not touch;
# a plain `mkdir -p` under the release umask would leave 0755 and put the
# daemon's socket where anyone can read it). An existing directory is left
# exactly as found — an installer that re-moded a tree it did not create would
# be overruling an operator, and `doctor` already reports the mode it sees.
ensure_user_tree() {
    _eut_me="$(id -u 2>/dev/null || true)"
    is_digits "$_eut_me" || _eut_me=""
    for _eut_d in "$TREE_ROOT" "$COMP_HOME" "$SOCKET_DIR"; do
        if [ -d "$_eut_d" ]; then
            tree_is_mine "$_eut_d" || refuse_foreign_tree "$_eut_d" "$_eut_me"
            continue
        fi
        if [ -e "$_eut_d" ]; then
            echo "error: $_eut_d exists and is not a directory." >&2
            echo "error: the cli keeps its own state there. Move it aside and re-run this installer." >&2
            echo "error: Nothing has been installed." >&2
            exit 1
        fi
        if ! mkdir -m 0700 "$_eut_d" 2>/dev/null; then
            echo "error: could not create $_eut_d." >&2
            echo "error: the cli keeps its identity, its config and its socket there, so the" >&2
            echo "error: install stops here rather than reporting success without it." >&2
            echo "error: Check that $(dirname "$_eut_d") exists and is writable by $(uid_label "$_eut_me")." >&2
            echo "error: Nothing has been installed." >&2
            exit 1
        fi
    done
}

ensure_user_tree

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

# ---- first-run bootstrap (interactive only, fresh installs) -------------------
# Re-install short-circuit: if this component already has persisted state under
# ~/.burrowee/<comp> (the gateway db/keys, cli/edge identity, …) it is already
# set up — never re-prompt for a setup blob. Otherwise read blob+PIN from the
# controlling terminal (stdin is the curl pipe, not a tty): prompt only if
# /dev/tty is genuinely usable (fd 3); if not (CI / detached) just print the
# next step. All tty I/O is fault-tolerant so it can never abort the install.
#
# THE EMPTY TREE IS NOT STATE, and saying so is what lets ensure_user_tree run
# first. This check used to read "$COMP_HOME is non-empty" as "already set up";
# now that the install CREATES $COMP_HOME/sockets before reaching here, that
# spelling would report every fresh install as already-configured and silently
# skip the setup prompt — the exact trap the ladder was kept below this check to
# avoid. So sockets/ is discounted, and nothing else is: the identity, the
# config, the self-copied installer and the version anchor all still mean this
# host has been here before.
if [ -d "$COMP_HOME" ] && [ -n "$(ls -A "$COMP_HOME" 2>/dev/null | grep -v '^sockets$' || true)" ]; then
    echo "$COMP already set up ($COMP_HOME) — skipping setup."
elif ( exec 3<>/dev/tty ) 2>/dev/null; then
    # PROBED IN A SUBSHELL, then opened for real. dash treats a FAILED `exec`
    # redirection as fatal and exits the script — status 2, and the `2>/dev/null`
    # swallows the only message — even inside a guarded `{ …; }` used as an `if`
    # condition, because a brace group is not a subshell and so does not contain
    # the exit. /bin/sh IS dash on every Debian-family host, and this block is
    # the LAST step of an otherwise complete install, so on exactly the hosts
    # that matter the shape it replaces turned every non-interactive install
    # (CI, a console push, `curl … | sh` under a supervisor) into a fully
    # installed cli reporting failure — and skipped the self-copy below, which
    # LocalReinstall needs. A subshell contains the fatal exit, so the parent
    # survives to answer the question and then open fd 3 for real.
    exec 3<>/dev/tty
    printf '\nSet up now? Paste the setup blob + PIN from the console (Enter to skip).\n' >&3 2>/dev/null || true
    printf 'blob> ' >&3 2>/dev/null || true
    blob=''; IFS= read -r blob <&3 2>/dev/null || blob=''
    if [ -n "$blob" ]; then
        printf 'pin>  ' >&3 2>/dev/null || true
        pin=''; IFS= read -r pin <&3 2>/dev/null || pin=''
        if [ -n "$pin" ]; then
            "$BIN_DIR/burrowee" "$COMP" bootstrap "$blob" "$pin" <&3 || true
        else
            printf 'No PIN — skipped. Run later: burrowee %s bootstrap <blob> <pin>\n' "$COMP" >&3 2>/dev/null || true
        fi
    else
        printf 'Skipped. Run later: burrowee %s bootstrap <blob> <pin>\n' "$COMP" >&3 2>/dev/null || true
    fi
    exec 3>&- 2>/dev/null || true
else
    echo "next: burrowee $COMP bootstrap <blob> <pin>"
fi

# ---------------------------------------------------------------------------
# EVERYTHING BELOW RUNS AFTER THE FIRST-RUN SETUP CHECK, and that ordering is
# load-bearing rather than incidental. That check reads a $COMP_HOME holding
# anything but the empty tree as "this cli is already set up", so anything that
# PUTS SOMETHING IN IT earlier — the ladder's receipts, the version anchor, the
# self-copy — would make every FRESH install look already-configured and
# silently skip the setup prompt. The self-copy below carried that constraint
# first; the ladder shares it.
#
# ensure_user_tree is the one thing that runs before the check, and it is why
# the check discounts sockets/ rather than testing for an empty directory: it
# creates the tree and puts NOTHING in it, so "empty tree" and "no tree" have to
# mean the same thing to a fresh install.
#
# Nothing here is destructive on a fresh host, so running it last costs only
# that a refusing ladder is reported after the prompt rather than before it.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# THE LADDER, then the installer's own sweep.
#
# MIGRATIONS_DIR is empty when this bundle carries none — a $COMP_HOME self-copy
# from an install predating the directory is exactly that, and it must still
# install rather than refuse. A bundle that HAS migrations/ and is missing a
# file inside it is the opposite case: a mis-assembled release, which this
# project has shipped once, and it is loud.
#
# ORDER: after the binaries are placed, before the version anchor is written.
# After, because the rung removes copies that shadow $BIN_DIR and removing them
# before the replacements exist would leave the operator's `burrowee` resolving
# to nothing for the length of an install. Before, because exit 3 means "the
# rung ran and its receipt was lost", and the only correct response is to
# withhold the anchor so the next install re-runs it — an anchor written first
# could not be withheld afterwards.
# ---------------------------------------------------------------------------
MIGRATIONS_DIR=""
if [ -d "$(dirname "$0")/migrations" ]; then
    MIGRATIONS_DIR="$(dirname "$0")/migrations"
fi

MIGRATE_UNRECORDED=0
if [ -n "$MIGRATIONS_DIR" ] && [ -f "$MIGRATIONS_DIR/run.sh" ]; then
    set +e
    COMP_HOME="$COMP_HOME" BIN_DIR="$BIN_DIR" sh "$MIGRATIONS_DIR/run.sh"
    _rc=$?
    set -e
    case "$_rc" in
    # 0 nothing applied · 2 migrations ran. This runner stops no service, so
    # there is nothing for this installer to start.
    0 | 2) ;;
    3) MIGRATE_UNRECORDED=1 ;;
    *)
        # 1 (refused/failed) or anything else is FATAL. Carrying on would write
        # the version anchor for a migration that refused, and the anchor is
        # what closes the gate on that rung permanently.
        echo "error: a state migration refused or failed — stopping." >&2
        echo "hint: the binaries are in $BIN_DIR; nothing else has been changed." >&2
        echo "hint: fix the cause reported above and re-run this installer." >&2
        exit 1
        ;;
    esac
fi

# The installer's OWN sweep, from the same shared library the rung uses. It
# stays here as well as being a rung, deliberately: a FRESH install must not
# depend on the ladder being coherent, the ladder is a no-op on a fresh host by
# construction, and the sweep is idempotent — running it twice costs a stat per
# name. install.sh runs only when somebody runs the installer and the updater
# never does, which is why the rung exists; the rung being new is not a reason
# to make fresh installs depend on it.
if [ -n "$MIGRATIONS_DIR" ]; then
    if [ -f "$MIGRATIONS_DIR/lib_stale_user_bins.sh" ] && [ -f "$MIGRATIONS_DIR/lib_paths.sh" ]; then
        # LIB_STALE_USER_BINS_DIR pins where the library finds its siblings.
        # Sourced from here, $0 is the BUNDLE ROOT and not migrations/, so
        # without this component.conf would never be found and the sweep would
        # silently have no names to sweep.
        LIB_STALE_USER_BINS_DIR="$MIGRATIONS_DIR"
        export LIB_STALE_USER_BINS_DIR
        # shellcheck source=/dev/null
        . "$MIGRATIONS_DIR/lib_paths.sh"
        # shellcheck source=/dev/null
        . "$MIGRATIONS_DIR/lib_stale_user_bins.sh"
        # THE TWO LISTS MUST AGREE. $BINS is what this installer PLACES;
        # $STALE_USER_BINS (from migrations/component.conf) is what the sweep
        # removes. A name in one and not the other is a binary installed and
        # never swept, or swept and never installed — and neither is visible
        # without saying so, because the sweep's normal output is nothing.
        if [ "$BINS" != "$STALE_USER_BINS" ]; then
            echo "note: this installer places [$BINS]" >&2
            echo "note: but $MIGRATIONS_DIR/component.conf sweeps [$STALE_USER_BINS]." >&2
            echo "note: the two lists disagree, so some name is installed and never swept" >&2
            echo "note: (it keeps shadowing $BIN_DIR on PATH) or swept and never installed." >&2
        fi
        remove_stale_user_bins
    else
        echo "note: $MIGRATIONS_DIR carries no lib_stale_user_bins.sh + lib_paths.sh pair —" >&2
        echo "note: THIS RELEASE IS INCOMPLETE. Stale per-user copies of these binaries are" >&2
        echo "note: NOT being swept. Re-run a complete release." >&2
    fi
fi

# ---- the migration ladder's version anchor ---------------------------------
# Withheld when a rung ran and could not be recorded: the receipt and the anchor
# are the two gates on a rung, and recording the version with the receipt lost
# closes the last one on work nothing on this host can prove finished.
if [ -n "${BURROWEE_VERSION:-}" ]; then
    if [ "$MIGRATE_UNRECORDED" = 1 ]; then
        echo "note: a migration completed but its receipt could not be written." >&2
        echo "note: the installed version is deliberately NOT recorded, so the next install" >&2
        echo "note: re-runs the migration (they are idempotent) rather than gating it off" >&2
        echo "note: on a version number with no receipt behind it." >&2
    elif printf '%s\n' "$BURROWEE_VERSION" > "$VERSION_MARKER.tmp" 2>/dev/null; then
        mv -f "$VERSION_MARKER.tmp" "$VERSION_MARKER" 2>/dev/null || echo "warning: could not record installed version" >&2
    else
        echo "warning: could not write version marker" >&2
    fi
fi

# Self-copy: keep a copy of this installer at $COMP_HOME/install.sh so an offline
# units-only reinstall (BURROWEE_UNITS_ONLY=1, run by cli's LocalReinstall) has a
# local installer to invoke. Written AFTER the setup check above so it never
# makes a fresh install look already-set-up.
cp "$0" "$COMP_HOME/install.sh" 2>/dev/null || true
# THE MIGRATIONS GO WITH IT. This script resolves the runner and the sweep
# library relative to its OWN path, so a $COMP_HOME holding install.sh without
# migrations/ is an installer that silently cannot migrate and silently stops
# sweeping — both of which look exactly like a clean run.
if [ -n "$MIGRATIONS_DIR" ] && [ "$MIGRATIONS_DIR" != "$COMP_HOME/migrations" ]; then
    mkdir -p "$COMP_HOME/migrations" 2>/dev/null || true
    cp "$MIGRATIONS_DIR"/* "$COMP_HOME/migrations/" 2>/dev/null \
        || echo "note: could not keep a copy of migrations/ at $COMP_HOME" >&2
fi

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
# WHAT IT REPLACED was a one-line note — "$BIN_DIR is not on PATH — add: export
# PATH=…" — under the same guard. The guard was right; the note was not. It
# named no shell and no profile file, so an operator whose login shell is fish
# was handed a line that is a syntax error there.
#
# NOTHING ELSE OWNS THIS ANY MORE. The outer bootstrap used to append a marked
# block to the operator's rc files after this script returned, which both
# duplicated the "Make it permanent" line and wrote bash syntax into a fish
# operator's ~/.bashrc. That block is deleted; see tools/bootstrap.template.sh.
#
# THE RENDERER IS THE SHARED LIBRARY'S, sourced above by the sweep block, and
# it resolves the subject from $SHELL and $HOME — which here are the operator's
# own and exact — instead of looking $SUDO_USER up in the passwd database. One
# renderer, two ways of learning who is asking.
#
# It is printed at the very END rather than beside the "installed to" line
# because the library is sourced further down, with the sweep, and because a
# next step reads better last. A bundle carrying no migrations/ at all (a
# $COMP_HOME self-copy predating the directory) still owes the operator the
# line, so the fallback prints it by hand — including the permanent half, which
# it used to drop.
case ":$PATH:" in
*":$BIN_DIR:"*) ;;
*)
    if command -v render_path_advice >/dev/null 2>&1; then
        render_path_advice "$BIN_DIR"
    else
        echo ""
        echo "==> Next steps"
        echo "burrowee's commands are in $BIN_DIR, which is not on your PATH."
        echo ""
        echo "  Add it to this shell now:"
        echo "    export PATH=\"$BIN_DIR:\$PATH\""
        echo ""
        echo "  Make it permanent by adding the line above to your shell's startup file."
        echo ""
        echo "  Then:  burrowee help"
    fi
    ;;
esac

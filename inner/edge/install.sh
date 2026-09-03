#!/bin/sh
# Burrowee inner installer — edge (POSIX sh, macOS + Linux).
#
# Ships at the ROOT of the verified release zip as `install.sh`. The outer
# bootstrap verifies the zip (minisign + sha256) and ONLY THEN execs this with
# cwd = the unzipped dir, so the binaries sit alongside this script.
#
# ROOT-ONLY, ONE DESTINATION, ONE MACHINE-OWNED TREE. The binaries go to
# $BIN_DIR — /usr/local/burrowee/bin, root-owned, ALWAYS — and the run sets up
# a MANAGED ROOT SERVICE: a systemd system unit on Linux, a launchd
# LaunchDaemon on macOS, running `burrowee-edge run`, enabled and
# (re)started. $BIN_DIR is one of three siblings under /usr/local/burrowee:
# bin/ (the execution surface), etc/edge (config: the identity) and var/edge
# (state). This script CREATES that tree with every level's owner and mode
# stated (ensure_system_tree) and asserts what it built before a unit names
# any of it (assert_system_tree). 0.2 placed the three roots under
# /usr/local/{bin,etc,var} — three directories that each had to be
# root-secure on their own, and on an Intel Mac with Homebrew two of them
# are not: brew chowns etc and var to the console user before burrowee is
# installed. One tree burrowee creates beside Homebrew's directories has one
# ancestor chain to verify, and it is one burrowee established rather than
# inherited. The operator-typed binaries are symlinked into /usr/local/bin
# where that directory is root-secure (link_operator_bins); the units,
# the updater and every root exec name the real path. The documented entry
# point is `curl ... | sudo sh`, which is what the console mints.
#
# THE PER-USER FLOW IS GONE, not de-defaulted. A PREFIX that would MISDIRECT the
# install is REFUSED, loudly (one that merely names this same destination is
# honoured and then cleared), and so is a run that never reached uid 0 — both
# before anything is placed,
# never silently redirected. This mirrors the gateway's 0.2.0 collapse
# (inner/gateway/install.sh, whose header carries the full reasoning) and exists
# for the same failure: a per-user install is invisible to every root-scheme
# consumer. The dispatcher resolves gateway/edge/register at the ABSOLUTE
# /usr/local/burrowee/bin, and a root daemon's unit pins
# PATH=/usr/bin:/bin:/usr/sbin:/sbin, so a PATH lookup from one can reach
# nothing under $HOME. Observed on a production node, 2026-08-13: a consumer's
# root daemon crash-looped 50 times unable to find a component that had
# "successfully installed" into /home/ubuntu/.local/bin. A component that
# installs where its consumers cannot look has not installed, however cleanly it
# exits.
#
# Removing the flow does not remove what it left behind, and the leftovers keep
# winning: $HOME/.local/bin PRECEDES /usr/local/bin on a normal PATH. So an
# install also sweeps the stale per-user copies of its own binaries, by exact
# name, after the units naming $BIN_DIR are loaded — sweep_stale_user_bins,
# which loads the shared migrations/lib_stale_user_bins.sh rather than
# open-coding a second copy of it. What it does NOT sweep is the per-user
# CONFIG tree an earlier unprivileged install paired: that holds this edge's
# identity, so it is reported, never touched — note_orphaned_user_state.
#
# THIS RELEASE ALSO CARRIES A MIGRATION LADDER (migrations/), and the sweep is
# a rung on it as well as a step here. install.sh runs only when somebody runs
# the installer and the updater never does, so a host updated in place kept its
# stale per-user copies indefinitely; the rung is what reaches those hosts. The
# ladder is walked unconditionally by run_migration_ladder and its exit code is
# acted on: 1 stops the install before any unit is written, 3 completes the
# install but withholds the version anchor.
#
# The system [Service] block mirrors the relay system unit (Restart / RestartSec
# / TimeoutStopSec / HOME); ExecStart is `<bin> run` (the edge daemon verb).
#
# Idempotent: re-running replaces the binaries + unit and restarts the service,
# so the same one-liner serves both fresh installs and in-place updates.
#
# Set BURROWEE_UNITS_ONLY=1 to re-render + reload the managed service units
# without touching binaries or the network — the offline reinstall entrypoint
# run by the component's LocalReinstall.
set -eu

BINS="burrowee burrowee-edge burrowee-edge-cli burrowee-edge-updater"
COMP=edge

# ── system install paths ─────────────────────────────────────────────────────
# SYS_BIN_DIR + SYSTEMD_UNIT_DIR + LAUNCHD_PLIST_DIR default to the real system
# locations; they are overridable only so the Go install-test harness can
# exercise this script in a sandbox without actually being root — never set them
# on a real host. SYS_BIN_DIR is this component's equivalent of the gateway's
# BURROWEE_BIN_DIR seam; it keeps its name because the rendered units, and every
# caller that already sets it, are written in terms of it.
#
# SYS_BIN_DIR and BIN_DIR are resolved BEFORE the PREFIX gate below, because the
# gate's whole question is "does this PREFIX name the destination we would have
# picked anyway?" — it cannot ask that without $BIN_DIR. These are assignments
# only: nothing is created, placed or written until well after the gate.
SYS_BIN_DIR="${SYS_BIN_DIR:-/usr/local/burrowee/bin}"
# BIN_DIR and SYS_BIN_DIR are ONE destination under two names: the units and the
# test harness spell it SYS_BIN_DIR, the placement/uninstall code below spells it
# BIN_DIR, and since the 0.2.0 collapse they can never differ. Resolved HERE, at
# the top, rather than beside the config home further down — the shared sweep
# library reads $BIN_DIR for the guard that refuses to sweep the install
# destination, and a library sourced before the value was decided would have
# taken the production default while this run installed somewhere else.
BIN_DIR="$SYS_BIN_DIR"
# LINK_BINS — the subset of $BINS an OPERATOR TYPES, and therefore the only
# names symlinked from $LINK_DIR (/usr/local/bin) into $BIN_DIR so that
# `burrowee-edge-cli …` keeps working with no PATH change now that the exec
# root is off PATH. burrowee-edge-updater is spawned by its unit, which names
# the real path (spec §6.1 rule 1), so it gets no link — and it is exactly
# what the 0.2→0.3 ladder rung sweeps out of /usr/local/bin, where 0.2 left a
# real copy of it. BURROWEE_LINK_DIR is a test-only seam like SYS_BIN_DIR.
LINK_BINS="burrowee burrowee-edge burrowee-edge-cli"
LINK_DIR="${BURROWEE_LINK_DIR:-/usr/local/bin}"
# What link_operator_bins actually linked. The exec-root sweep leaves every
# operator-typed name that is NOT in here alone: with no link at that path the
# real 0.2 file is the only copy anything reaches by it.
LINKED_OPERATOR_BINS=""

# exec_root_keep_list — the operator-typed names no link will replace on this
# host, resolved BEFORE anything runs so the ladder rung can be handed it too.
# When $LINK_DIR is not root-secure link_operator_bins creates nothing, and the
# real 0.2 file at each of those names stays the only copy anything reaches by
# the absolute path — the shared `burrowee` dispatcher above all. The
# installer's own later call narrows this to what it actually linked.
exec_root_keep_list() {
    # EVERY operator-typed name, unconditionally. This is what the LADDER is
    # handed, and the ladder runs before link_operator_bins has made a single
    # link — so at that moment no link has replaced anything, and the real 0.2
    # file at each of these names is still the only copy reachable by the
    # absolute path. The installer's own sweep, which runs after linking,
    # narrows this to the names it could not link (LINKED_OPERATOR_BINS).
    echo "$LINK_BINS"
}
# The 0.2 exec root the sweep reads IS the link directory, so it follows the
# same seam: a sandboxed run must never iterate the host's real /usr/local/bin.
LEGACY_BIN_DIR="${LEGACY_BIN_DIR:-$LINK_DIR}"

# normalize_dir PATH — collapse repeated slashes and strip trailing ones, so
# '/usr/local/bin', '/usr/local//bin' and '/usr/local/bin/' all name the same
# directory. Root ('/') stays '/'. Used ONLY to compare two directory names.
#
# printf '%s', NEVER echo. dash's echo (and bash's under xpg_echo) expands
# backslash escapes in its argument, so an echo-based normaliser reduces
# PREFIX='/usr/local/bin\c' to '/usr/local/bin' and ACCEPTS a prefix that is not
# this destination at all — the one thing this gate exists to catch.
#
# TEXTUAL ONLY — no '.'/'..' folding, no symlink resolution, no relative-path
# anchoring. A PREFIX spelled '/usr/local/../local' or '/usr/local/.' is NOT
# recognised as the destination and is refused. Deliberate and sufficient: the
# one value this has to recognise is core's injected PREFIX, which is already
# filepath.Dir-clean and absolute, and a guard that resolved symlinks would be
# claiming to know where a path LANDS, which is a different (and racy) question
# from the one being asked here.
normalize_dir() {
    _nd="$(printf '%s' "$1" | sed -e 's|//*|/|g' -e 's|/*$||')"
    printf '%s' "${_nd:-/}"
}

# A DIVERGENT PREFIX IS REFUSED — a PREFIX that names THIS destination is not —
# and it is refused HERE, before a directory is created, a binary placed or a
# unit written. Refusing the divergent one is the point: an operator who typed
# PREFIX=$HOME/.local and got a root-owned /usr/local/bin would be handed exactly
# the class of surprise this collapse exists to remove, one direction reversed.
# They get told instead, and the process that set it (a shell profile, an outer
# bootstrap, a wrapper) is the thing that has to change. The version is named
# because the operator hitting this needs to know since when; it is asserted by
# the suite (install_test/root_only_test.go), so it cannot drift away from the
# release it describes without a test failing.
#
# But refusing EVERY set PREFIX refuses callers that are naming the one true
# destination, which misdirects nothing — and that blanket shape is what wedged
# relay's entire fleet on 2026-08-22: core's updater injects
# PREFIX=<dirname²(ServeBin)> = /usr/local when it runs these scripts, so every
# auto/push update died with "PREFIX is set to '/usr/local' … nothing has been
# updated". Today this installer survives that only because core strips PREFIX
# for root-only components before exec — i.e. the fresh-install path is protected
# by a Go change rather than by the rule. The rule is the guard's subject: a copy
# landing where the units never execute, and only that.
if [ -n "${PREFIX:-}" ]; then
    _prefix_bin="$(normalize_dir "$PREFIX/bin")"
    _true_bin="$(normalize_dir "$BIN_DIR")"
    if [ "$_prefix_bin" = "$_true_bin" ]; then
        # printf, not echo, for every line that interpolates the caller's own
        # value: dash's echo would expand a backslash escape inside $PREFIX and
        # silently truncate the very line meant to quote it back.
        printf '%s\n' "install: PREFIX ('$PREFIX') names this installer's own destination ($_true_bin) — proceeding."
        # Absent, not empty: an ACCEPTED PREFIX is cleared right here, so nothing
        # downstream can read it as a fallback. The migration ladder is handed
        # its environment with the `VAR=x sh run.sh` form, which ADDS to the
        # environment rather than replacing it, and the shared rungs read
        # BIN_DIR="${BIN_DIR:-${PREFIX:-/usr/local}/bin}" — harmless only while
        # BIN_DIR is passed explicitly and wins, i.e. one deletion away from
        # mattering. Cleared, never set to "": absent, not empty, as core does it.
        unset PREFIX
    else
        # The refusal carries BOTH spellings of the destination: the literal
        # /usr/local/burrowee/bin (production truth, and what the suite's static
        # pins check) and the resolved $_true_bin. They differ only when the
        # SYS_BIN_DIR test seam is set, and an operator reading a refusal on a
        # real host must see the real path either way.
        #
        # printf, not echo, on the two lines that interpolate caller-controlled
        # text: a PREFIX containing a backslash escape ('\c' ends echo's output
        # in dash) would otherwise truncate the refusal at the moment it quotes
        # the offending value, hiding the component, the destination and the
        # "nothing has been installed" line all at once.
        printf '%s\n' "install: PREFIX is set to '$PREFIX', but as of edge 0.2.0 this installer" >&2
        echo "install: has one destination: /usr/local/burrowee/bin, root-owned. The per-user" >&2
        echo "install: prefix flow is gone — edge's service units run as root and name the" >&2
        echo "install: binaries absolutely, and other components resolve" >&2
        echo "install: /usr/local/burrowee/bin/burrowee by absolute path, so a per-user copy" >&2
        echo "install: is invisible to both." >&2
        printf '%s\n' "install: (a PREFIX resolving to $_true_bin is honoured; '$_prefix_bin' is not it.)" >&2
        echo "hint: unset PREFIX and re-run; nothing has been installed." >&2
        exit 1
    fi
    unset _prefix_bin _true_bin
fi

SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
SYSTEMD_UNIT="$SYSTEMD_UNIT_DIR/burrowee-edge.service"
SYSTEMD_UPDATER_UNIT="$SYSTEMD_UNIT_DIR/burrowee-edge-updater.service"
LAUNCHD_PLIST_DIR="${LAUNCHD_PLIST_DIR:-/Library/LaunchDaemons}"
LAUNCHD_PLIST="$LAUNCHD_PLIST_DIR/com.burrowee.edge.plist"
LAUNCHD_LABEL="com.burrowee.edge"
LAUNCHD_UPDATER_PLIST="$LAUNCHD_PLIST_DIR/com.burrowee.edge.updater.plist"
LAUNCHD_UPDATER_LABEL="com.burrowee.edge.updater"
# Legacy pre-rename system labels/plists earlier installers wrote — migrated
# away on install, removed on uninstall.
LEGACY_LAUNCHD_LABEL="org.burrowee.edge"
LEGACY_LAUNCHD_UPDATER_LABEL="org.burrowee.edge.updater"

# remove_legacy_launchd_units — boot out + delete the org.burrowee.* system
# LaunchDaemons a pre-rename root install wrote. Best-effort; root-only caller.
remove_legacy_launchd_units() {
    launchctl bootout "system/$LEGACY_LAUNCHD_LABEL" 2>/dev/null || true
    launchctl bootout "system/$LEGACY_LAUNCHD_UPDATER_LABEL" 2>/dev/null || true
    rm -f "$LAUNCHD_PLIST_DIR/$LEGACY_LAUNCHD_LABEL.plist" \
          "$LAUNCHD_PLIST_DIR/$LEGACY_LAUNCHD_UPDATER_LABEL.plist"
}

is_root() { [ "$(id -u)" = 0 ]; }

# === ROOT-SECURE CONTRACT BEGIN ===
# Everything between this line and the matching END line is BYTE-IDENTICAL in
# every inner installer that creates or verifies a machine-owned tree:
#
#   burrowee-git/release  inner/gateway/install.sh   (this copy is the reference)
#   burrowee-git/release  inner/edge/install.sh
#   burrowee-git/relay    install.sh                  (relay's inner installer
#                                                      lives in its own repo)
#
# It is duplicated rather than sourced because it must run even when a bundle
# carries no migrations/ directory at all (BURROWEE_UNITS_ONLY re-runs a kept
# self-copy that may predate one), and because the gateway does not take the
# shared ladder — inner/_shared is not in a gateway kit. The drift is guarded
# instead of prevented: tools/shelllint/root_secure_contract_test.go compares
# the two copies in this repo byte for byte, and the relay repo pins its copy
# against this one. Edit one, edit all; nothing outside the sentinels is
# compared, so the callers may differ freely.
#
# The functions below are the WHOLE predicate — the shell half of
# core/binary's IsRootSecure (files) and IsRootSecureDir (directories).
# Anything that changes what "root-secure" means belongs in here.
#
# THE TWO PREDICATES IN HERE DO NOT CURRENTLY ANSWER THE SAME-STRENGTH
# QUESTION, and the name of this region must not be read as promising that
# they do:
#
#   dir_is_root_secure  walks the path COMPONENT BY COMPONENT from /,
#                       resolving each symlink where it is met, so it judges
#                       every directory substitutable for any component —
#                       lexical chain, resolved chain, and the holder of every
#                       link on the way.
#   path_is_root_secure walks its ancestors LEXICALLY and resolves nothing, so
#                       for a symlinked ancestor it never judges the chain that
#                       holds the ancestor's TARGET. On Linux it happens to
#                       refuse such a path because a symlink stats 0777; on
#                       macOS a symlink stats 0755 and it does not.
#
# The weaker of the two is the one that gates a root EXEC (the unit's
# ProgramArguments, the updater's ServeBin, RootExecInstallScript, every
# RequireRootSecureExec subject). That is a known, reported gap with its own
# surface and its own callers; closing it is its own change with its own
# red-first tests, deliberately not folded into the directory form's — this
# function has had four defects found in it in one day, three of them
# introduced while fixing the previous one.

# ---------------------------------------------------------------------------
# The stat dialect, decided once.
#
# `stat` has two incompatible dialects, and the same letter means different
# things in each: GNU coreutils takes the format as `-c FORMAT`, BSD/macOS as
# `-f FORMAT` — and on GNU, `-f` is `--file-system`. So `stat -f '%u' PATH` on
# Linux does not fail cleanly. It reads '%u' as a SECOND PATH: dumps PATH's
# filesystem geometry to STDOUT, complains about '%u' on stderr, and exits 1.
# A `stat -f … || stat -c …` chain therefore prints that dump CONCATENATED with
# the real answer, so `[ "$(stat_uid p)" = 0 ]` is false for a file owned by
# root. That shipped, and it made path_is_root_secure below answer "not secure"
# for every path on every Linux host — refusing the install of a tree that was
# already correct, and pointing the operator at permissions as the cause.
#
# Hence: probe ONCE against a path that certainly exists, then always use the
# flag that was proved to work. Ordering `-c` first would also work today (BSD
# stat rejects `-c` with a usage error on stderr and NOTHING on stdout — this is
# verified by the suite, not assumed), but it leaves every call a speculative
# failing exec whose correctness rests on that stdout/stderr split holding for
# every stat any host might carry. Probing does not rest on anything.
# ---------------------------------------------------------------------------

# is_digits <s> — true when s is one or more decimal digits and nothing else.
# Rejecting a MULTI-LINE blob is the entire point: every newline and every word
# of a filesystem dump is a non-digit, so a concatenated answer can never be
# mistaken for a value.
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

# stat_field <gnu-format> <bsd-format> <path> — one numeric field of one file,
# in whichever dialect this host speaks.
#
# It prints exactly one line of digits, or it prints NOTHING and returns
# non-zero. There is no third outcome, and callers depend on that: a helper that
# can put junk on stdout turns every `[ "$(…)" = 0 ]` into a silent false, which
# reads to an operator as "your permissions are wrong" rather than "I could not
# look" — two problems with nothing in common.
stat_field() {
    case "$STAT_FLAVOR" in
    gnu) _sf_v="$(stat -c "$1" "$3" 2>/dev/null)" || return 1 ;;
    bsd) _sf_v="$(stat -f "$2" "$3" 2>/dev/null)" || return 1 ;;
    *) return 1 ;;
    esac
    is_digits "$_sf_v" || return 1
    printf '%s\n' "$_sf_v"
}

# stat_uid / stat_mode <path> — owner uid (decimal) and permission bits
# (octal). No output and non-zero on any failure — never a partial answer.
stat_uid() {
    stat_field '%u' '%u' "$1"
}
stat_mode() {
    stat_field '%a' '%Lp' "$1"
}

# mode_allows_nonroot_write <octal> — true when the group or other digit carries
# the write bit. The last two characters are those two digits for every width
# stat emits ("755", "1777"), so no zero-padding assumption is needed.
mode_allows_nonroot_write() {
    _mm="$1"
    [ "${#_mm}" -ge 2 ] || return 0    # unreadable mode: assume the worst
    _mg=$(printf '%s' "$_mm" | cut -c "$((${#_mm} - 1))")
    _mo=$(printf '%s' "$_mm" | cut -c "${#_mm}")
    case "$_mg" in 2 | 3 | 6 | 7) return 0 ;; esac
    case "$_mo" in 2 | 3 | 6 | 7) return 0 ;; esac
    return 1
}

# path_is_root_secure <path> — the shell half of the same predicate the Go side
# applies (internal/gateway/system_tool.IsRootSecure): a regular file owned by
# uid 0, not group- or world-writable, reachable only through directories that
# are themselves root-owned and unwritable by non-root, all the way to /.
#
# The ancestor walk is the load-bearing half. A root-owned binary inside a
# user-writable directory can be unlinked and replaced by that user, after which
# root execs their file — so checking the leaf alone proves nothing.
#
# FOUR return codes, not two:
#   0  secure
#   1  not secure — a real answer about a real path that EXISTS
#   2  undecidable — stat did not answer, so nothing is known either way
#   3  the leaf does not exist at all — a different question than 1, and one
#      that must not be answered with 1's message. It is reachable: an update
#      mode may deliberately leave one name unplaced this run (the gateway's
#      ROOT_BIN_PLACE_EXCLUDE skips its own running updater) while the
#      verification still checks it, because a unit is about to name it
#      either way — and a host converging off an older layout has never had
#      one at $BIN_DIR. "Not root-owned" would blame ownership on a path that
#      was never created, sending an operator to check permissions on nothing.
#
# 1 and 2 are separated because they send an operator to completely different
# places, and collapsing them is what the dialect bug above actually cost: a
# host whose tree was already root:root 755 was told to go and check its
# permissions. A predicate guarding a root exec must still REFUSE on 2 — but it
# must refuse saying it could not look. 3 is separated from 1 for the same
# reason: "insecure" and "absent" are different facts, and only one of them is
# fixed by permissions.
path_is_root_secure() {
    _rs_p="$1"
    [ -f "$_rs_p" ] || return 3
    _rs_v="$(stat_uid "$_rs_p")" || return 2
    [ "$_rs_v" = 0 ] || return 1
    _rs_v="$(stat_mode "$_rs_p")" || return 2
    if mode_allows_nonroot_write "$_rs_v"; then return 1; fi
    _rs_d="$(dirname "$_rs_p")"
    while :; do
        [ -d "$_rs_d" ] || return 1
        _rs_v="$(stat_uid "$_rs_d")" || return 2
        [ "$_rs_v" = 0 ] || return 1
        _rs_v="$(stat_mode "$_rs_d")" || return 2
        if mode_allows_nonroot_write "$_rs_v"; then return 1; fi
        _rs_parent="$(dirname "$_rs_d")"
        [ "$_rs_parent" != "$_rs_d" ] || break
        _rs_d="$_rs_parent"
    done
    return 0
}

# dir_spelling_normalize <path> — sets $_dsn_out to <path> with the trailing
# spellings removed that do not change WHICH DIRECTORY IS NAMED.
#
# THIS IS THE ONE HOME FOR THAT RULE, and it is a function rather than four
# lines inline because the question "does this path name a symlink at its final
# component" has now been answered wrongly three times in this file's history,
# every time by somebody looking at one spelling. A predicate about a DIRECTORY
# must be a function of the directory, not of how a caller spelled it, and
# these are the spellings a caller can legally pass:
#
#   X                 the leaf is X. Tested as given.
#   X/  X//           the same directory: a trailing separator only forces the
#                     kernel to resolve X as a directory. STRIPPED — otherwise
#                     `[ -L X/ ]` is false for a symlinked X and the refusal
#                     below is one character away from being bypassed.
#   X/.  X/./  X/.//. `.` names the directory itself, so it never changes which
#                     directory is named. STRIPPED, repeatedly, interleaved
#                     with the separators above.
#   X/..              a DIFFERENT directory — X's parent, after symlink
#                     resolution. NOT stripped, and it never needs to be: `..`
#                     from any directory yields a real directory, so a path
#                     ending in /.. cannot have a symlinked leaf.
#   a/./b  a//b       interior; they do not touch the leaf. The walk skips and
#                     collapses them, and `[ -L a/./b ]` lstats b correctly.
#   bin  ./bin        relative; lstat anchors them to the working directory
#                     exactly as the walk does.
#   alias/bin         a symlinked ALIAS in an ANCESTOR position. The leaf is
#                     the real directory b; the alias is followed and judged
#                     like any other ancestor.
#
# It sets a variable rather than printing one because a command substitution
# would strip a trailing newline from the ARGUMENT it is handed, and because
# every caller here is inside `set -eu`. That is a statement about this
# function only — the readlink in the walk below does go through a command
# substitution, and says at its own site what that costs and why it stands.
dir_spelling_normalize() {
    _dsn_out="$1"
    while :; do
        case "$_dsn_out" in
        /) break ;;
        */) _dsn_out="${_dsn_out%/}" ;;
        */.) _dsn_out="${_dsn_out%/.}" ;;
        *) break ;;
        esac
    done
    # "/." and "/" both name the root, and the loop above empties the first —
    # but ONLY a rooted input can empty, so the restoration is guarded on that.
    # Unguarded it also fired for an EMPTY OPERAND, turning "" into "/" and
    # answering "root-secure" for an unset variable: a rule written for one
    # input shape firing on another, which is the third time in this change.
    # The caller's own guard is below, in dir_is_root_secure.
    case "$1" in
    /*) [ -n "$_dsn_out" ] || _dsn_out=/ ;;
    esac
}

# dir_leaf_is_symlink <path> — true when the directory <path> names is reached
# through a symlink at its FINAL component, in any legal spelling. Exported
# from this region so a CALLER can ask the same question the predicate asked:
# dir_is_root_secure answers 1 for this and for "somebody on the way can
# rewrite it", and a caller that reports only the second sends an operator to
# audit ownership and modes that are perfectly correct.
dir_leaf_is_symlink() {
    dir_spelling_normalize "$1"
    [ -L "$_dsn_out" ]
}

# dir_absence_is_real <path> — true when a false `[ -d <path> ]` is a FACT
# about <path> rather than a permission on the way to it. `[ -d ]` answers
# false both when the path is not a directory and when this process cannot
# SEARCH the parent to find out, and those are the file's 1-vs-2 split in
# miniature. The second is ORDINARY here, not exotic: this walk descends
# through directories it has just judged root-owned, and a root-owned 0700
# one — $SYS_DATA_DIR's own shape — passes that judgement and is then
# unsearchable by the unprivileged operator this installer runs as. Answering
# "not secure" there sends them to check permissions that are exactly right.
dir_absence_is_real() {
    _dar_p="$1"
    case "$_dar_p" in
    */*)
        _dar_p="${_dar_p%/*}"
        [ -n "$_dar_p" ] || _dar_p=/
        ;;
    *) _dar_p=. ;;
    esac
    [ -x "$_dar_p" ]
}

# dir_is_root_secure <path> — the directory form of the predicate above, and
# the shell half of core/binary's IsRootSecureDir. Same four codes; the leaf is
# a DIRECTORY, so 3 means "no such directory" rather than "no such file". The
# leaf and every ancestor up to / must be owned by uid 0 and carry no group or
# other write bit — the leaf is walked exactly like an ancestor, because a
# directory is where root's STATE is about to be created and a group-writable
# one lets that group replace what root wrote.
#
# It is a separate function rather than a flag on path_is_root_secure because
# the two are asked in different places for different reasons: one gates a
# root EXEC, the other gates where root's state is about to be created, and a
# shared flag would let a caller ask the wrong question with a one-character
# typo — a directory passed to the file form answers 3 ("absent"), which reads
# as "nothing to check" rather than as the wrong question.
#
# THE PROPERTY, stated over components rather than over one resolved string:
# every directory that could be SUBSTITUTED for any component of the path is
# root-owned and unwritable by non-root. That is every component of the path as
# spelled, every component of the path it resolves to, and — for each symlink
# met on the way — the chain of directories that holds that link.
#
# THE WALK THEREFORE GOES DOWNWARD, ONE COMPONENT AT A TIME, RESOLVING EACH
# SYMLINK WHERE IT IS MET. Collapsing the path first — `cd "$(dirname …)" &&
# pwd -P` — and walking upward from the result is what this replaces, and it
# was wrong in a way no leaf test can repair: physical resolution ERASES every
# intermediate symlink, so neither the link nor the chain holding it is ever
# stat'ed. With /usr group-writable and /usr/local a symlink into a root-owned
# /opt/burrowee-local, the collapsed chain (/opt/burrowee-local/bin, /opt, /)
# walks perfectly clean and the install proceeds — after which any member of
# /usr's group repoints /usr/local at a tree they own, taking the identity and
# host-cert directory this installer is about to create and the exec root root
# will run binaries from. A `[ -L ]` test added for the LEAF does not reach it
# either: the leaf was never the substitutable component.
#
# Downward is also what makes the holder chain free. Each component is judged
# BEFORE the walk descends through it, so by the time a symlink is followed the
# directory holding it has already been judged; following it just re-enters the
# same loop on the target, from / again when the target is absolute, judging
# that chain the same way.
#
# A SYMLINK'S OWN uid AND MODE ARE DELIBERATELY NOT TESTED. Replacing a symlink
# is governed by write permission on the directory that holds it — the
# component already judged — and the link's own mode is not even portable:
# 0777 on Linux, 0755 on macOS. Testing it would refuse every symlinked path on
# one platform and none on the other, which is a dialect bug wearing a security
# check's clothes.
#
# A SYMLINKED LEAF IS FOLLOWED AND JUDGED ON BOTH CHAINS — the holder's and the
# target's — and it is NOT refused here. The refusal core/binary's
# IsRootSecureDir applies belongs to ONE caller, not to this predicate, and the
# difference is the whole of an operator ruling:
#
#   IsRootSecureDir is wired at exactly one place, internal/gateway's config
#   root. Its reason is specific to that: "a config root that is a symlink is
#   not a packaging fact, it is somebody redirecting where the daemon writes
#   its secrets" (root_secure_unix.go). A briefly-shipped form of this function
#   refused a symlinked leaf for EVERY root the installer asserts —
#   $SYSTEM_ROOT, $BIN_DIR, the etc/var roots and $SYS_DATA_DIR as well as the
#   config root — and "put var on the big disk" is an ordinary supported
#   layout: those installs worked before, are never rejected by the daemon, and
#   would have started failing hard. A refusal that breaks a working layout is
#   a worse outcome than the one it prevents there.
#
# So the rule is applied where its justification reaches and no further:
# dir_leaf_is_symlink is what a caller asks, and only the CONFIG root's caller
# asks it. Every other root keeps the both-chains judgement below, which is
# what actually protects them.
#
# A symlinked ANCESTOR is always followed and judged — that is the substitution
# this walk exists to catch, and Go accepts it too (too readily: see the region
# header).
#
# NOTHING HERE ENTERS THE DIRECTORY IT IS ASKED ABOUT, and nothing here `cd`s
# at all. This script runs UNPRIVILEGED and elevates per step, and the leaf is
# routinely root-owned 0700 ($SYS_DATA_DIR): `cd` into that is EACCES for the
# operator, and an earlier form that did it refused every non-root install with
# a message about `stat` dialects. `[ -d ]`, `[ -L ]`, `readlink` and `stat` on
# a path all need search permission on its PARENT only, and every parent this
# walk touches must be 0755-and-root-owned to pass at all.
dir_is_root_secure() {
    # An EMPTY operand answers 3: it names no directory, `[ -d "" ]` is false
    # for it by specification, and dir_spelling_normalize is what makes sure it
    # still is — see the guard there. It must never answer 0, which it did
    # while that guard was missing. A second check here would state the same
    # rule twice and leave neither one testable: delete either and the suite
    # stays green, so the rule lives in exactly one place.
    # ONE normalization, here, before anything looks at the spelling —
    # dir_spelling_normalize owns which spellings name the same directory.
    dir_spelling_normalize "$1"
    _ds_in="$_dsn_out"
    if [ ! -d "$_ds_in" ]; then
        if dir_absence_is_real "$_ds_in"; then return 3; fi
        return 2
    fi
    case "$_ds_in" in
    /*) _ds_rest="$_ds_in" ;;
    *)
        # A relative spelling is judged against the physical working directory,
        # whose own components are then walked like any other. `pwd -P` reports
        # the cwd this process already has; it enters nothing.
        _ds_cwd="$(pwd -P 2>/dev/null)" || return 2
        [ -n "$_ds_cwd" ] || return 2
        _ds_rest="${_ds_cwd%/}/$_ds_in"
        ;;
    esac
    # / is a component like any other, and the only one the loop below never
    # reaches — every candidate it builds hangs off it.
    dir_level_is_root_secure / || return $?
    _ds_done=''    # the prefix already judged, fully resolved; '' means /
    _ds_hops=0     # symlinks followed, so the loop terminates come what may
    while :; do
        # Separators, however many, carry no component.
        while :; do
            case "$_ds_rest" in
            /*) _ds_rest="${_ds_rest#/}" ;;
            *) break ;;
            esac
        done
        [ -n "$_ds_rest" ] || return 0
        case "$_ds_rest" in
        */*)
            _ds_comp="${_ds_rest%%/*}"
            _ds_rest="${_ds_rest#*/}"
            ;;
        *)
            _ds_comp="$_ds_rest"
            _ds_rest=''
            ;;
        esac
        case "$_ds_comp" in
        .) continue ;;
        # .. after a resolved prefix pops that prefix, exactly as the kernel
        # resolves it — and the popped directory was judged on the way in.
        ..)
            _ds_done="${_ds_done%/*}"
            continue
            ;;
        esac
        _ds_cur="$_ds_done/$_ds_comp"
        if [ -L "$_ds_cur" ]; then
            _ds_hops=$((_ds_hops + 1))
            # A cycle cannot arrive through the `[ -d ]` above — the kernel
            # resolved the whole path to get there, and refuses a loop long
            # before this bound. It is a path rewritten UNDERNEATH the walk
            # that this stops, and "I could not follow it" is undecidable,
            # not insecure.
            [ "$_ds_hops" -le 64 ] || return 2
            # KNOWN LIMIT, stated because the region asserts the opposite
            # invariant one function up and a reader is entitled to see them
            # reconciled: `$( )` strips every trailing newline, so a link whose
            # TARGET's last component ends in one is resolved here one
            # character short of what the kernel follows, and the walk then
            # judges a different directory than the one asked about.
            #
            # It is left as it is, deliberately. Recovering the bytes needs the
            # `&& printf X` guard plus removal of readlink's own terminator,
            # and whether readlink writes that terminator is a DIALECT question
            # of the same kind that cost this file the stat bug — so the
            # recovery would need its own probe, and a probe that is wrong
            # truncates every target instead of one. Against that: creating
            # such a link requires write access to the directory holding it,
            # and this walk refuses any chain a non-root account can write, so
            # the only account that can set one up is the one the predicate
            # exists to trust. A wrong answer here is root's about root's.
            #
            # dir_spelling_normalize's comment says it avoids a command
            # substitution to keep a path entitled to a trailing newline; that
            # is true of the ARGUMENT it is handed and is not a claim about
            # this line.
            _ds_t="$(readlink "$_ds_cur" 2>/dev/null)" || return 2
            [ -n "$_ds_t" ] || return 2
            case "$_ds_t" in
            /*)
                _ds_done=''
                _ds_rest="${_ds_t#/}/$_ds_rest"
                ;;
            *) _ds_rest="$_ds_t/$_ds_rest" ;;
            esac
            continue
        fi
        dir_level_is_root_secure "$_ds_cur" || return $?
        _ds_done="$_ds_cur"
    done
}

# dir_level_is_root_secure <dir> — one already-resolved component of the walk:
# it is a directory, root owns it, and nobody else may write it. Codes 0, 1 and
# 2 carry dir_is_root_secure's meanings. 3 is not this function's to answer:
# only the leaf can legitimately be absent, and that is settled before the walk
# starts. A component that has stopped being a directory mid-walk is 1 — the
# path no longer denotes what it was asked about — but a component this process
# cannot even reach is 2, per dir_absence_is_real: the walk descends through
# root-owned directories, a root-owned 0700 one passes and is unsearchable by
# an unprivileged operator, and reporting that as "not secure" is the exact
# misdirection the 1-vs-2 split exists to prevent.
dir_level_is_root_secure() {
    if [ ! -d "$1" ]; then
        if dir_absence_is_real "$1"; then return 1; fi
        return 2
    fi
    _dl_v="$(stat_uid "$1")" || return 2
    [ "$_dl_v" = 0 ] || return 1
    _dl_v="$(stat_mode "$1")" || return 2
    if mode_allows_nonroot_write "$_dl_v"; then return 1; fi
    return 0
}
# === ROOT-SECURE CONTRACT END ===

# ---------------------------------------------------------------------------
# THE STALE PER-USER BINARY SWEEP, AND THE MIGRATION LADDER IT NOW ALSO RIDES ON
#
# Until the 0.2.0 collapse the unprivileged branch dropped the binaries in
# $HOME/.local/bin, and before the managed root service existed that was the
# only shape an edge install took. A host converging onto the root scheme gets
# everything in the root-owned exec root (/usr/local/bin in 0.2, $BIN_DIR since
# 0.3) and keeps the old copies — and $HOME/.local/bin PRECEDES either on a
# normal PATH, so every unqualified `burrowee` or
# `burrowee-edge-cli` an operator types resolves to the OLD binary while the
# system unit runs the new one.
#
# THE SWEEP IS NOT OPEN-CODED HERE ANY MORE. It lives in
# migrations/lib_stale_user_bins.sh, inside this same bundle, and the 0.2.0
# ladder rung (migrations/stale_user_bins.sh) sources the same file out of the
# same directory. Every guard in it fails silently in the safe-looking direction
# — a sweep pointed at the wrong home finds nothing and reports success; an
# ownership check that admits too much deletes an operator's own file and
# reports success too — so a second copy that drifted would look exactly like
# the original right up to the deletion it got wrong.
#
# IT IS ALSO A LADDER RUNG NOW, and that is why the drift was worth fixing.
# install.sh runs only when somebody runs the installer, and THE UPDATER NEVER
# DOES: it runs update.sh, swaps binaries and restarts the daemon. So a host
# updated in place kept its stale per-user copies forever. Making the sweep a
# rung is what reaches those hosts; keeping the call HERE as well is deliberate
# rather than redundant, because a FRESH install must not depend on the ladder
# being coherent, and the sweep is idempotent.
#
# THE ORDERING IS A SAFETY PROPERTY, not a tidiness preference. A host arriving
# here may still be running a unit whose ExecStart names the per-user path; the
# macOS LaunchDaemons this script writes gate KeepAlive on PathState, so
# unlinking the binary does not stale a future restart — it stops the running
# daemon. So the sweep runs only after the new binaries are in $SYS_BIN_DIR and
# the units naming them have been rendered and (re)loaded, and even then it
# refuses outright when a unit file on this host still names the old directory.
#
# THE BINARIES ARE ALL IT TOUCHES. The per-user CONFIG tree beside them
# (~/.burrowee/edge: this edge's identity, console.json, covers) is this host's
# pairing, and the root daemon reads a different one — so it is REPORTED and
# left exactly where it is (note_orphaned_user_state). Deleting it would throw
# away the only copy of an identity; moving it would silently re-point a paired
# edge, from an installer, with no operator in the loop.
# ---------------------------------------------------------------------------

# The library spells the unit directories LAUNCHD_DIR / SYSTEMD_DIR — the same
# names the gateway's installer and the gateway repo's runner use. This script
# (and every caller that already sets them, including the Go install-test
# harness) spells them LAUNCHD_PLIST_DIR / SYSTEMD_UNIT_DIR. Mapped here, once,
# so a sandboxed run cannot leak into the real /Library/LaunchDaemons.
LAUNCHD_DIR="$LAUNCHD_PLIST_DIR"
SYSTEMD_DIR="$SYSTEMD_UNIT_DIR"

# MIGRATIONS_DIR — the ladder shipped beside this installer, or empty when this
# bundle carries none. A bundle with no migrations/ is an OLD bundle, not a
# broken one (a $COMP_HOME self-copy from an install that predates the
# directory, reachable only through BURROWEE_UNITS_ONLY), so it stays quiet —
# while a bundle that HAS migrations/ and is missing a file inside it is a
# mis-assembled release, which this project has shipped once and must never
# ship quietly again.
MIGRATIONS_DIR=""
if [ -d "$(dirname "$0")/migrations" ]; then
    MIGRATIONS_DIR="$(dirname "$0")/migrations"
fi

# SWEEP_LIB_LOADED gates both call sites below. It is a separate variable and
# not a test of $MIGRATIONS_DIR, because "the directory is there" and "the
# functions are defined" are different facts and the second is the one the
# callers depend on.
SWEEP_LIB_LOADED=0
if [ -n "$MIGRATIONS_DIR" ]; then
    if [ -f "$MIGRATIONS_DIR/lib_stale_user_bins.sh" ] && [ -f "$MIGRATIONS_DIR/lib_paths.sh" ]; then
        # LIB_STALE_USER_BINS_DIR pins where the library looks for its siblings
        # (lib_paths.sh, component.conf). Without it the library resolves them
        # from $0 — which, sourced from here, is the BUNDLE ROOT and not
        # migrations/, so component.conf would never be found and the sweep
        # would silently have no names to sweep.
        LIB_STALE_USER_BINS_DIR="$MIGRATIONS_DIR"
        export LIB_STALE_USER_BINS_DIR
        # shellcheck source=/dev/null
        . "$MIGRATIONS_DIR/lib_paths.sh"
        # shellcheck source=/dev/null
        . "$MIGRATIONS_DIR/lib_stale_user_bins.sh"
        SWEEP_LIB_LOADED=1
        # THE TWO LISTS MUST AGREE. $BINS is what this installer PLACES;
        # $STALE_USER_BINS (from migrations/component.conf) is what the sweep
        # removes, and it is the one the ladder rung uses too. A name added to
        # one and not the other is a binary that is installed and never swept —
        # a shadowing copy left on PATH, which is this whole defect — or one
        # swept and never installed. Neither is visible without saying so out
        # loud, because the sweep's normal output on a converged host is nothing
        # at all.
        if [ "$BINS" != "$STALE_USER_BINS" ]; then
            echo "note: this installer places [$BINS]" >&2
            echo "note: but $MIGRATIONS_DIR/component.conf sweeps [$STALE_USER_BINS]." >&2
            echo "note: the two lists disagree, so some name is installed and never swept" >&2
            echo "note: (it keeps shadowing $BIN_DIR on PATH) or swept and never installed." >&2
        fi
    else
        echo "note: $MIGRATIONS_DIR carries no lib_stale_user_bins.sh + lib_paths.sh pair —" >&2
        echo "note: THIS RELEASE IS INCOMPLETE. The pre-0.2.0 per-user copies of these" >&2
        echo "note: binaries are NOT being swept, and they precede $BIN_DIR on a normal" >&2
        echo "note: PATH. Remove them by hand, or re-run a complete release." >&2
    fi
fi

# sweep_stale_user_bins — run the library's sweep, or say why it cannot.
# Named differently from the library's own remove_stale_user_bins on purpose:
# two definitions of one name in one shell, with which one a call reaches
# depending on whether the source has happened yet, is not a hazard worth
# creating to save a word.
sweep_stale_user_bins() {
    [ "$SWEEP_LIB_LOADED" = 1 ] || return 0
    remove_stale_user_bins
}

# sweep_stale_exec_root — the 0.2 exec root's real copies (/usr/local/bin),
# left behind when 0.3 moved the binaries to $BIN_DIR. Same library, same
# guards, same reason it runs HERE as well as on the ladder
# (migrations/sweep_stale_exec_root.sh): the rung runs before this installer
# re-renders the units, and while a 0.2 unit still names
# /usr/local/bin/burrowee-edge-updater the library correctly refuses to
# unlink it — so on the first 0.3 install the rung is a no-op and this call,
# after setup_root_service, is what actually clears the copies.
sweep_stale_exec_root() {
    [ "$SWEEP_LIB_LOADED" = 1 ] || return 0
    # The exec-root half lives OUTSIDE the byte-pinned SHARED SWEEP CONTRACT
    # region, so a kit whose library predates it must say so — not abort under
    # `set -eu` with "not found", which here would land AFTER the units are
    # already re-rendered and loaded. Same guard, same wording, as the gateway.
    if ! command -v remove_stale_exec_root_bins >/dev/null 2>&1; then
        echo "note: the loaded sweep library has no remove_stale_exec_root_bins — THIS RELEASE IS" >&2
        echo "note: INCOMPLETE: the 0.2 copies in $LEGACY_BIN_DIR were not swept." >&2
        return 0
    fi
    STALE_EXEC_ROOT_KEEP=""
    for _ssk in $LINK_BINS; do
        case " $LINKED_OPERATOR_BINS " in
        *" $_ssk "*) ;;
        *) STALE_EXEC_ROOT_KEEP="${STALE_EXEC_ROOT_KEEP:+$STALE_EXEC_ROOT_KEEP }$_ssk" ;;
        esac
    done
    remove_stale_exec_root_bins
}

# ---------------------------------------------------------------------------
# run_migration_ladder — walk migrations/run.sh, which runs every migration in
# migrations/ledger this host has not reached yet, oldest first.
#
# The runner owns the whole decision: it reads the version anchor, gates each
# rung on `installed < target`, runs them oldest first, and records each one
# that completes. It is a no-op unless one applies, so this is called
# UNCONDITIONALLY — a caller that decided for itself when the ladder was worth
# running would be a second copy of the gate.
#
# WHERE IT SITS IN THE FLOW, and why. It runs after the binaries are in
# $BIN_DIR and before the version marker is written:
#
#   * AFTER the binaries, because the 0.2.0 rung removes the per-user copies
#     that SHADOW $BIN_DIR on PATH. Removing them before the replacements exist
#     would leave an operator's `burrowee-edge-cli` resolving to nothing at all
#     for the length of an install.
#   * BEFORE the version marker, because exit 3 means "the rung ran and its
#     receipt was lost", and the only correct response to that is to withhold
#     the anchor so the next install re-runs the rung. An anchor written before
#     the ladder ran could not be withheld after it.
#
# EXIT CODES — the runner's contract, acted on rather than merely observed:
#   0  nothing applied. Continue.
#   2  migrations ran. Continue. (This runner stops no service — see its header.)
#   3  ran, but a receipt was lost: continue, and DO NOT record the version.
#   1 or anything else  FATAL. Stopping here leaves the binaries placed and no
#      units written, which is loud and re-runnable; carrying on would write
#      units and an anchor for a migration that refused, and the anchor is what
#      closes the gate on that rung permanently.
#
# Not found is not an error: BURROWEE_UNITS_ONLY can run from $COMP_HOME's
# self-copy, and an install predating migrations/ has none beside it.
# ---------------------------------------------------------------------------
MIGRATE_UNRECORDED=0
run_migration_ladder() {
    [ -n "$MIGRATIONS_DIR" ] || return 0
    [ -f "$MIGRATIONS_DIR/run.sh" ] || return 0
    # Both roots exist by now (ensure_system_tree, before anything is placed),
    # and the runner is handed BOTH: for a `system`-scheme component it refuses a
    # $COMP_HOME without a $COMP_DATA rather than pairing a named tree with a
    # defaulted one, which is what keeps the installer and the ladder from
    # describing two different installs.
    set +e
    COMP_HOME="$COMP_HOME" \
        COMP_DATA="$COMP_DATA" \
        SYS_CONFIG_ROOT="$SYS_CONFIG_ROOT" \
        SYS_DATA_ROOT="$SYS_DATA_ROOT" \
        BIN_DIR="$BIN_DIR" \
        LEGACY_BIN_DIR="$LEGACY_BIN_DIR" \
        STALE_EXEC_ROOT_KEEP="$(exec_root_keep_list)" \
        LEGACY_SYS_CONFIG_ROOT="$LEGACY_SYS_CONFIG_ROOT" \
        LEGACY_SYS_DATA_ROOT="$LEGACY_SYS_DATA_ROOT" \
        LAUNCHD_DIR="$LAUNCHD_PLIST_DIR" \
        SYSTEMD_DIR="$SYSTEMD_UNIT_DIR" \
        sh "$MIGRATIONS_DIR/run.sh"
    _rml_rc=$?
    set -e
    case "$_rml_rc" in
    0 | 2) ;;
    3) MIGRATE_UNRECORDED=1 ;;
    *)
        echo "error: a state migration refused or failed — stopping before the service" >&2
        echo "error: units are written and the binaries are in $BIN_DIR." >&2
        # NOT "nothing else has been changed": edge declares
        # SERVICE_STOP_RUNGS="adopt_user_tree.sh", so a rung MAY have stopped the
        # daemon before the ladder failed. The runner says on stderr when it did;
        # this message must not contradict that by claiming the host is untouched,
        # and must not claim the stop happened either — re-running the installer
        # is the fix in both cases, and the start command is here for an operator
        # who needs the daemon up before that.
        echo "error: a migration may have STOPPED the $COMP service before failing —" >&2
        echo "error: check the runner's output above." >&2
        if [ "$(uname -s)" = "Darwin" ]; then
            echo "hint: start it with: sudo launchctl kickstart -k system/$LAUNCHD_LABEL" >&2
        else
            echo "hint: start it with: sudo systemctl start burrowee-edge" >&2
        fi
        echo "hint: fix the cause reported above and re-run this installer." >&2
        exit 1
        ;;
    esac
}

# report_unrecorded_migration — say that a migration completed without its
# receipt, and that the version anchor was withheld on purpose so it runs again.
report_unrecorded_migration() {
    [ "$MIGRATE_UNRECORDED" = 1 ] || return 0
    echo "note: a migration completed but its receipt could not be written." >&2
    echo "note: the installed version is deliberately NOT recorded, so the next install" >&2
    echo "note: re-runs the migration (they are idempotent) rather than gating it off" >&2
    echo "note: on a version number with no receipt behind it." >&2
}

# note_orphaned_user_state — REPORT, and never touch, a home-shaped config tree
# that holds this host's pairing while the managed service reads elsewhere.
#
# TWO CANDIDATES, the same two the adoption rung takes its source from: ROOT's
# ~/.burrowee/edge (a 0.2.0 host, from the collapse or from the manual copy made
# during the outage) and the OPERATOR's (a pre-collapse host). Neither travels
# with the binaries, so a host converging onto the machine-owned roots comes up
# as a healthy, running, UNPAIRED edge. Silence is the worst outcome available
# here: the install exits 0, the service is up, and nothing gives the operator a
# reason to look for the identity that already exists a directory away.
#
# Says nothing when there is no such state. That $COMP_HOME is unpaired is the
# CALLER's condition — this is only reached from the "next: pair this edge"
# branch — and it is not re-tested here: a second copy of a condition its only
# call site already decided cannot fail independently, it can only drift.
#
# It resolves both homes through the SAME operator_home/root_home the sweep and
# the ladder use — one definition, in migrations/lib_paths.sh — so the directory
# it reports on and the directory the rung would act on can never be two
# different answers. With no library loaded it says nothing rather than guessing
# $HOME, which under `sudo sh` is root's: a report naming the wrong directory is
# worse than no report, because it is acted on.
note_orphaned_user_state() {
    [ "$SWEEP_LIB_LOADED" = 1 ] || return 0
    _nos_seen=""
    for _nos_dir in "$(root_home)/.burrowee/$COMP" "$(operator_home)/.burrowee/$COMP"; do
        [ -n "$_nos_dir" ] || continue
        case "$_nos_dir" in "/.burrowee/$COMP") continue ;; esac
        [ "$_nos_dir" = "$COMP_HOME" ] && continue
        [ "$_nos_dir" = "$COMP_DATA" ] && continue
        case " $_nos_seen " in *" $_nos_dir "*) continue ;; esac
        _nos_seen="$_nos_seen $_nos_dir"
        [ -d "$_nos_dir/identity" ] || [ -f "$_nos_dir/console.json" ] || continue
        echo "note: $_nos_dir holds a paired edge identity from an earlier install," >&2
        echo "note: but the managed service reads $COMP_HOME — this edge starts UNPAIRED." >&2
        echo "hint: the migration ladder adopts it (root's tree first when both exist);" >&2
        echo "hint: force it with  sh $COMP_HOME/migrations/upgrade.sh 0.2.0" >&2
        echo "hint: or pair again (burrowee $COMP cli bootstrap <blob> <pin>). Nothing was removed." >&2
    done
}

# ── the one install target ───────────────────────────────────────────────────
# The service's config home. $BIN_DIR was decided at the top of this file,
# beside $SYS_BIN_DIR — there is no branch left to take, so every step below
# that only made sense for a root install (setup_root_service, the unit teardown
# on uninstall, the stale-bin sweep, the version marker under root's home) now
# runs on EVERY install.
#
# TWO MACHINE-OWNED ROOTS, not root's home. Spec
# 2026-08-13-burrowee-root-install-shared-cli-design §3 gave edge the system
# roots at the same time it gave them to the gateway; 0.2.0 shipped the binary
# move without the layout and the daemon kept reading
# $ROOT_HOME/.burrowee/edge — i.e. whichever home the supervisor exported.
#
#   $COMP_HOME  /usr/local/burrowee/etc/edge  config: identity/, console.json,
#               the operator's `config`, bridge/, host-cert/, lan-cert/,
#               cf-token, installed-version, migration-receipts/, migrations/,
#               this installer's self-copy. Backed up, never cleared.
#   $COMP_DATA  /usr/local/burrowee/var/edge  state: config.json, logs/, stats/,
#               covers/, running.json. Rewritten while the daemon serves and
#               reclaimable.
#
# Both under /usr/local/burrowee since 0.3, beside $BIN_DIR — the same
# constants the Go side resolves through core's system_root (ConfigRoot /
# DataRoot + "edge"). The 0.2 pair (/usr/local/etc/burrowee/edge,
# /usr/local/var/burrowee/edge) is what the shared ladder's v0_2_to_v0_3.sh
# rung copies FROM, and it is left exactly as found.
#
# SYS_CONFIG_ROOT / SYS_DATA_ROOT are overridable only for the Go install-test
# harness, like SYS_BIN_DIR. They are NOT a supported operator knob and no
# shipped unit names anything derived from them but these two paths.
SYS_CONFIG_ROOT="${SYS_CONFIG_ROOT:-/usr/local/burrowee/etc}"
SYS_DATA_ROOT="${SYS_DATA_ROOT:-/usr/local/burrowee/var}"
# The 0.2 roots, handed to the ladder so its transitional anchor read stays
# inside whatever tree this run was pointed at. Left to default there, the
# runner would resolve the REAL /usr/local/etc/burrowee/edge on a sandboxed
# run and drive the version gate off the host's own anchor — the same leak
# LEGACY_BIN_DIR was fixed for.
LEGACY_SYS_CONFIG_ROOT="${LEGACY_SYS_CONFIG_ROOT:-/usr/local/etc/burrowee}"
LEGACY_SYS_DATA_ROOT="${LEGACY_SYS_DATA_ROOT:-/usr/local/var/burrowee}"
COMP_HOME="$SYS_CONFIG_ROOT/$COMP"
COMP_DATA="$SYS_DATA_ROOT/$COMP"
VERSION_MARKER="$COMP_HOME/installed-version"
# THE TREE ABOVE THE THREE ROOTS. In production all three parents are the one
# directory /usr/local/burrowee. It is DERIVED from the seamed leaves rather
# than spelled as a fourth seam so that a sandboxed run can never reach
# outside its sandbox: a suite that redirects $SYS_BIN_DIR to <tmp>/bin has,
# by construction, redirected the tree to <tmp> as well. Nothing above it is
# ever created or re-moded by this script: /usr/local is not ours.
SYSTEM_ROOT="$(dirname "$SYS_BIN_DIR")"

# ---------------------------------------------------------------------------
# The post-start daemon wait (see wait_for_running_version, and the tail of this
# script). WAIT_CEILING is a CEILING, not a sleep: the wait returns the instant
# the daemon reports the version being installed, and $WAIT_INTERVAL is only how
# often it looks.
#
# Overridable for the shell test harnesses, exactly like SYS_BIN_DIR above, and
# for nothing else — an operator has no reason to retune this and no documented
# knob to do it with. Deliberately NOT spelled BURROWEE_*: those are the
# published knobs the bootstrap forwards across its sudo boundary
# (tools/bootstrap-env-forwarding.test.sh), and these two are not published.
#
# SERVE_UNIT_STARTED is the wait's gate — 1 only once the SERVE unit has been
# (re)started AND verified up by start_unit_darwin / start_unit_linux. There is
# nothing to wait for when nothing was restarted — which includes a mode that
# stages the units without starting them, and only ONE of the three components
# sharing this block has one: gateway reads BURROWEE_NO_RESTART, edge and relay
# read it nowhere, so for them the gate is the start itself and nothing else.
# Nor when the start already failed: that path has already said so, and spending
# the ceiling to rediscover a known failure is noise on top of it. A started
# UPDATER never sets it — a live updater says nothing about the daemon that
# serves.
# ---------------------------------------------------------------------------
WAIT_INTERVAL="${WAIT_INTERVAL:-2}"
WAIT_CEILING="${WAIT_CEILING:-60}"
SERVE_UNIT_STARTED=0

# $ROOT_HOME is still resolved, and it is no longer where anything lives. The
# units set HOME=$ROOT_HOME (below) purely so a library that dereferences $HOME
# has a real directory to find: systemd exports none to a root unit and launchd
# exports none at all, and os.UserHomeDir() then fails with "$HOME is not
# defined" — which on the gateway killed the updater agent on every start until
# the supervisor gave up. Nothing about edge's config or state is derived from
# it any more; internal/edgeroot resolves both roots without consulting $HOME.
# The stale-tree note and the adoption rung still name it, because it is one of
# the two places an already-enrolled host's state may currently be.
#
# root_home() from migrations/lib_paths.sh is the ONE implementation of that
# rule, shared with the migration runner. The inline fallback below is reached
# only by a bundle that carries no migrations/ at all — a $COMP_HOME self-copy
# predating the directory, which only BURROWEE_UNITS_ONLY runs — and it is
# deliberately the same rule rather than a simplification of it.
if command -v root_home >/dev/null 2>&1; then
    ROOT_HOME="$(root_home)"
elif [ "$(uname -s)" = "Darwin" ]; then
    ROOT_HOME="${ROOT_HOME:-$(eval echo ~root)}"
    case "$ROOT_HOME" in /*) ;; *) ROOT_HOME=/var/root ;; esac
else
    ROOT_HOME="${ROOT_HOME:-/root}"
fi

# ---------------------------------------------------------------------------
# THE MACHINE-OWNED TREE: created level by level with the mode STATED, then
# asserted with the same predicate the daemon applies.
#
# Everything created inside the tree gets its ownership and mode stated
# explicitly. Neither may arrive by inheritance, because every source of
# inheritance is wrong: `mkdir -p` applies the process umask (under 022 a
# 0700 argument still yields 0755, under 002 a 0755 one yields 0775 —
# group-writable, which dir_is_root_secure refuses); `unzip` restores the
# mode the payload recorded, so a binary stored group-writable extracts
# group-writable (every binary is placed with `install -m 0755`, never
# `cp -p`); and `cp` takes the copy's mode from the source.
#
# A NON-ROOT PROCESS MUST NEVER BE THE ONE TO CREATE ANY OF IT: on a host
# where /usr/local is writable by the installing user (Intel macOS, where
# Homebrew chowns it) an unprivileged mkdir succeeds and leaves the root
# daemon writing identity/relay_ed.key — whose pubkey IS this node's
# fingerprint — and the host-cert private key inside a directory that user
# fully controls. Edge's installer is root-only, so is_root is the whole
# check; a non-root run refuses here rather than half-creating the tree.
#
# The whole tree is OURS by construction: /usr/local/burrowee is created by
# root beside Homebrew's directories rather than inside them, so every level
# is moded unconditionally — there is no "somebody else's parent" to leave
# alone, which the 0.2 layout could never say about /usr/local/etc. The one
# directory this never touches is the parent of $SYSTEM_ROOT (/usr/local): a
# missing one is a refusal, not a mkdir.
#
# 0700 on the component leaves, 0755 on the parents. Neither of edge's two
# leaves publishes anything to a non-owner (the gateway's etc/gateway is 0755
# for its admin-group console.token; edge has no such grant), and the
# parents hold no files at all.
# ---------------------------------------------------------------------------

# ensure_dir_stated <dir> <octal-mode> — one level: create it when absent
# (plain mkdir — the caller states EVERY level, and a level whose parent is
# missing is a level outside the tree this script owns), then own and mode
# it. chmod is checked; chown is best-effort, because the assertion that
# follows (assert_system_tree) is what decides ownership — a chown that
# "succeeded" proves nothing a stat does not. A steady-state re-run costs
# stats and no writes: nothing is touched unless the stat disagrees.
ensure_dir_stated() {
    _eds_d="$1"; _eds_m="$2"
    if [ ! -d "$_eds_d" ]; then
        if [ ! -d "$(dirname "$_eds_d")" ]; then
            echo "error: cannot create $_eds_d — its parent $(dirname "$_eds_d") does not exist," >&2
            echo "error: and this installer creates nothing above $SYSTEM_ROOT." >&2
            echo "error: nothing has been installed; no binary was placed." >&2
            return 1
        fi
        if ! mkdir "$_eds_d"; then
            echo "error: could not create $_eds_d — nothing has been installed; no binary was placed." >&2
            return 1
        fi
    fi
    if [ "$(stat_uid "$_eds_d" 2>/dev/null || echo -)" != 0 ]; then
        chown 0:0 "$_eds_d" 2>/dev/null || true
    fi
    if [ "$(stat_mode "$_eds_d" 2>/dev/null || echo -)" != "${_eds_m#0}" ]; then
        if ! chmod "$_eds_m" "$_eds_d"; then
            echo "error: could not chmod $_eds_m $_eds_d — refusing to leave a level of the" >&2
            echo "error: machine-owned tree at a mode this installer did not state." >&2
            echo "error: nothing has been installed; no binary was placed." >&2
            return 1
        fi
    fi
}

# ensure_system_tree — the whole tree, top-down, one level at a time, then
# asserted. The three chains meet at $SYSTEM_ROOT in production (bin/, etc/
# and var/ are siblings under /usr/local/burrowee); under the test seams
# each leaf may hang off its own sandbox parent, which is why each chain
# names its own parent rather than assuming the first one's. Refuses a
# non-root run before creating anything.
ensure_system_tree() {
    if ! is_root; then
        echo "error: $0 must run as root — it creates $COMP_HOME and $COMP_DATA," >&2
        echo "error: and whatever an unprivileged process creates, that user owns." >&2
        exit 1
    fi
    ensure_dir_stated "$SYSTEM_ROOT" 0755 || exit 1
    ensure_dir_stated "$SYS_BIN_DIR" 0755 || exit 1
    ensure_dir_stated "$(dirname "$SYS_CONFIG_ROOT")" 0755 || exit 1
    ensure_dir_stated "$SYS_CONFIG_ROOT" 0755 || exit 1
    ensure_dir_stated "$COMP_HOME" 0700 || exit 1
    ensure_dir_stated "$(dirname "$SYS_DATA_ROOT")" 0755 || exit 1
    ensure_dir_stated "$SYS_DATA_ROOT" 0755 || exit 1
    ensure_dir_stated "$COMP_DATA" 0700 || exit 1
    assert_system_tree || exit 1
}

# have_real_root — whether uid 0 is what the FILESYSTEM sees for what this
# run creates. is_root answers what `id` says; the sandboxed harness stubs
# `id` to say 0 while every file it creates belongs to the test user, and
# asserting ownership there would refuse every test run for a reason that
# says nothing about a real host. Asking the filesystem who owns a file this
# run just made answers the question directly. Cached: it costs a create.
HAVE_REAL_ROOT=""
have_real_root() {
    if [ -z "$HAVE_REAL_ROOT" ]; then
        _hrr="$SYSTEM_ROOT/.burrowee-owner-probe.$$"
        HAVE_REAL_ROOT=no
        if ( umask 077; : >"$_hrr" ) 2>/dev/null && [ "$(stat_uid "$_hrr" 2>/dev/null || echo -)" = 0 ]; then
            HAVE_REAL_ROOT=yes
        fi
        rm -f "$_hrr"
    fi
    [ "$HAVE_REAL_ROOT" = yes ]
}

# assert_system_tree — refuse when any root of the tree is not root-owned and
# unwritable by non-root all the way to /, with the same predicate the daemon
# applies (dir_is_root_secure, the shell half of IsRootSecureDir). An
# invariant checked only at first daemon start is one the operator meets as
# a broken service; checked here it is a failed install naming the directory
# that caused it. rc 1 (insecure), 2 (undecidable) and 3 (absent) are three
# refusals with three different next steps and are kept apart.
assert_system_tree() {
    if ! have_real_root; then
        echo "note: this run's files are not owned by uid 0, so the ownership of $SYSTEM_ROOT" >&2
        echo "note: cannot be asserted — skipping the root-secure check on the tree." >&2
        return 0
    fi
    for _ast in "$SYSTEM_ROOT" "$SYS_BIN_DIR" "$SYS_CONFIG_ROOT" "$COMP_HOME" "$SYS_DATA_ROOT" "$COMP_DATA"; do
        _ast_rc=0
        dir_is_root_secure "$_ast" || _ast_rc=$?
        if [ "$_ast_rc" = 0 ]; then continue; fi
        if [ "$_ast_rc" = 2 ]; then
            # TWO causes, and naming only one sends the operator to the wrong
            # place. dir_is_root_secure walks the path component by component,
            # so it answers 2 when a `stat` did not answer AND when a symlink
            # on the way could not be followed — the second has nothing to do
            # with which stat is on PATH. Asserting a dialect problem here
            # would be the same misdirection the 1-vs-2 split exists to stop.
            echo "error: could not establish the owner and mode of every directory on the" >&2
            echo "error: way to $_ast, so nothing is known either way." >&2
            echo "error: refusing to install — edge's state would sit in a directory whose" >&2
            echo "error: ownership could not be established." >&2
            echo "hint: the permissions of $_ast are NOT implicated — reading them is." >&2
            echo "hint: two things answer this way. Either this host's 'stat' answered" >&2
            echo "hint: neither the GNU form (stat -c '%u') nor the BSD form (stat -f '%u')" >&2
            echo "hint: with a plain number — check which stat is on PATH ('command -v stat')" >&2
            echo "hint: and that it is the system one; or a symlink on the way could not be" >&2
            echo "hint: followed, which is what a path rewritten while it is walked looks" >&2
            echo "hint: like, and a re-run settles that one." >&2
            echo "hint: then re-run the installer." >&2
        elif [ "$_ast_rc" = 3 ]; then
            echo "error: $_ast does not exist — refusing to install a service whose state" >&2
            echo "error: would sit in a directory this run failed to create." >&2
        else
            echo "error: $_ast is not root-owned and unwritable all the way to /." >&2
            echo "error: refusing to install — edge's state would sit in a directory a" >&2
            echo "error: non-root user could rewrite." >&2
            echo "hint: check the ownership and modes of that directory and every directory" >&2
            echo "hint: above it; each must be owned by root and not group- or world-writable." >&2
        fi
        return 1
    done
    # THE CONFIG ROOT ALONE MAY NOT BE A SYMLINK, mirroring exactly what
    # core/binary's IsRootSecureDir refuses and no more. Every root above keeps
    # the both-chains judgement, which is what protects them; a symlinked
    # $SYS_DATA_DIR or $SYSTEM_ROOT is the ordinary "put var on the big disk"
    # layout, it installed cleanly before, and the daemon never rejects it.
    #
    # Checked AFTER the loop, deliberately: by here every directory on the way
    # to it has been judged, so the line below saying ownership is not what
    # refused this run is a statement this function has actually established
    # rather than one it asserts on the way past. A tree with both problems
    # gets the ownership refusal first, fixes it, and then gets this one —
    # each message true when it is given.
    if dir_leaf_is_symlink "$COMP_HOME"; then
        echo "error: $COMP_HOME is a SYMLINK, and the machine-owned CONFIG root must" >&2
        echo "error: be a real directory — whatever the link points at, and however well" >&2
        echo "error: owned that target is." >&2
        echo "error: refusing to install — the daemon mints its console token and identity" >&2
        echo "error: into this directory, a link is a redirection of where those are written," >&2
        echo "error: and nothing about its target's ownership records that it moved or stops" >&2
        echo "error: it moving again. The daemon refuses it at first start; refusing here" >&2
        echo "error: is that same answer, given while the install can still be fixed." >&2
        echo "hint: ownership and modes are not what refused this run — every directory on" >&2
        echo "hint: the way to it was checked and passed." >&2
        echo "hint: point the setting at the real directory, or replace the link with the" >&2
        echo "hint: directory itself; then re-run the installer." >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# THE /usr/local/bin SYMLINKS (spec §6.1). The exec root is
# /usr/local/burrowee/bin, which is on nobody's PATH; the binaries an operator
# types are linked from $LINK_DIR so `burrowee-edge-cli …` still resolves.
#
# RULE 2 IS THE ONE THAT MATTERS: link ONLY into a root-secure directory. A
# root-owned symlink is necessary but not sufficient — `unlink` is governed by
# write permission on the CONTAINING directory, so in a Homebrew-owned
# /usr/local/bin any user can delete root's link and drop their own file at
# that name, and the operator's next `sudo burrowee-edge-cli` runs it as
# root. Root ownership of the link is not the protection; the directory's is.
# So dir_is_root_secure is asked FIRST, and on anything but 0 no link is
# created at all — the one line that adds the exec root to PATH is printed
# instead.
#
# RULE 3: created as root, REPLACING whatever is there — `rm -f` then
# `ln -sfn`, never a write through an existing link or file. Every 0.2 host
# carries a real /usr/local/bin/burrowee-edge-cli, and a stale regular file
# left in place shadows the new install completely.
#
# RULE 1 is enforced by the renderers, not here: every unit and the updater's
# ServeBin name $SYS_BIN_DIR. The links exist for humans. RULE 4 is
# unlink_operator_bins below. NEVER FATAL: a link is a convenience.
# ---------------------------------------------------------------------------
link_operator_bins() {
    _lob_rc=0
    dir_is_root_secure "$LINK_DIR" || _lob_rc=$?
    if [ "$_lob_rc" != 0 ]; then
        case "$_lob_rc" in
        3) echo "note: $LINK_DIR does not exist on this host, so no burrowee command was linked into it." ;;
        2) echo "note: the ownership of $LINK_DIR could not be established — either 'stat' answered neither" ;
           echo "note: dialect, or a symlink on the way could not be followed — so no burrowee command was linked" ;
           echo "note: into it: a link is only safe in a directory proven root-owned." ;;
        *) echo "note: $LINK_DIR is not root-owned and unwritable by non-root all the way to /, so no burrowee" ;
           echo "note: command was linked into it — in a directory another user can write, root's own link can be" ;
           echo "note: unlinked and replaced, and the next 'sudo burrowee-edge-cli' would run that user's file as root." ;;
        esac
        echo "note: run edge's commands by their real path, or add the exec root to PATH:"
        echo "    export PATH=\"$BIN_DIR:\$PATH\""
        return 0
    fi
    _lob_linked=""
    for _lob in $LINK_BINS; do
        [ -f "$BIN_DIR/$_lob" ] || continue
        if [ -L "$LINK_DIR/$_lob" ] && [ "$(readlink "$LINK_DIR/$_lob")" = "$BIN_DIR/$_lob" ]; then
            _lob_linked="${_lob_linked:+$_lob_linked }$_lob"
            continue
        fi
        # ATOMIC, never unlink-then-relink. A 0.2 macOS plist holds
        # KeepAlive.PathState on $LINK_DIR/burrowee-<comp>; an `rm -f` there
        # makes launchd observe the watched path vanish and SIGTERM the running
        # daemon — the one the operator may be tunnelled through — which it then
        # restarts from the OLD in-memory job definition now resolving through
        # the new link. Building the link beside its name and renaming it over
        # closes that window: rename(2) within one directory is atomic, so the
        # path is never absent. rule 3's "replace, never write through" still
        # holds — a real file at the name is replaced, not followed.
        _lob_tmp="$LINK_DIR/.burrowee-link.$$.$_lob"
        if ! ln -sfn "$BIN_DIR/$_lob" "$_lob_tmp" 2>/dev/null; then
            echo "note: could not stage a link in $LINK_DIR for $_lob; run it by its real path." >&2
            continue
        fi
        if ! mv -f "$_lob_tmp" "$LINK_DIR/$_lob"; then
            rm -f "$_lob_tmp" 2>/dev/null || true
            echo "note: could not put $LINK_DIR/$_lob in place — it still shadows $BIN_DIR/$_lob; remove it by hand." >&2
            continue
        fi
        _lob_linked="${_lob_linked:+$_lob_linked }$_lob"
    done
    LINKED_OPERATOR_BINS="$_lob_linked"
    [ -z "$_lob_linked" ] || echo "linked into $LINK_DIR: $_lob_linked"
}

# unlink_operator_bins — RULE 4: removed on uninstall, and only when the link
# still points into OUR tree. A regular file at one of these names is the
# operator's; a symlink pointing anywhere else is somebody else's.
unlink_operator_bins() {
    for _uob in $LINK_BINS; do
        _uob_p="$LINK_DIR/$_uob"
        [ -L "$_uob_p" ] || continue
        case "$(readlink "$_uob_p")" in
        "$BIN_DIR"/*) ;;
        *) continue ;;
        esac
        # A link whose target still exists is still serving someone: the shared
        # `burrowee` dispatcher stays in $BIN_DIR while a sibling component is
        # installed, and its link must stay with it.
        [ -e "$_uob_p" ] && continue
        rm -f "$_uob_p" || echo "note: could not remove the link $_uob_p — remove it by hand" >&2
    done
}

# ver_lt A B — true (exit 0) when version A < B, comparing the vMAJOR.MINOR.PATCH
# prefix numerically (any .date.sha suffix is ignored). Empty A sorts as 0.0.0.
ver_lt() {
    _a="${1#v}"; _b="${2#v}"
    _a1=$(printf '%s' "$_a" | cut -d. -f1); _a1=$(printf '%s' "${_a1:-0}" | tr -cd 0-9); _a1=${_a1:-0}
    _a2=$(printf '%s' "$_a" | cut -d. -f2); _a2=$(printf '%s' "${_a2:-0}" | tr -cd 0-9); _a2=${_a2:-0}
    _a3=$(printf '%s' "$_a" | cut -d. -f3); _a3=$(printf '%s' "${_a3:-0}" | tr -cd 0-9); _a3=${_a3:-0}
    _b1=$(printf '%s' "$_b" | cut -d. -f1); _b1=$(printf '%s' "${_b1:-0}" | tr -cd 0-9); _b1=${_b1:-0}
    _b2=$(printf '%s' "$_b" | cut -d. -f2); _b2=$(printf '%s' "${_b2:-0}" | tr -cd 0-9); _b2=${_b2:-0}
    _b3=$(printf '%s' "$_b" | cut -d. -f3); _b3=$(printf '%s' "${_b3:-0}" | tr -cd 0-9); _b3=${_b3:-0}
    [ "$_a1" -lt "$_b1" ] && return 0; [ "$_a1" -gt "$_b1" ] && return 1
    [ "$_a2" -lt "$_b2" ] && return 0; [ "$_a2" -gt "$_b2" ] && return 1
    [ "$_a3" -lt "$_b3" ] && return 0
    return 1
}

# seed_if_absent KEY VAL — set the config key only when unset (never clobber an
# operator value). burrowee-edge-cli `config get` exits non-zero when absent.
seed_if_absent() {
    if "$BIN_DIR/burrowee-edge-cli" config get "$1" >/dev/null 2>&1; then
        return 0
    fi
    "$BIN_DIR/burrowee-edge-cli" config set "$1" "$2" >/dev/null 2>&1 \
        || echo "warning: could not seed default $1=$2" >&2
}

# migrate_config OLD — apply version-gated default seeds. Each block runs
# only when crossing into the version that introduced its default.
migrate_config() {
    _old="$1"
    # introduced v0.1.32 — high-throughput smux buffers (the buffer-profile feature):
    if ver_lt "$_old" "v0.1.32"; then
        seed_if_absent buffer_stream  32m
        seed_if_absent buffer_session 256m
    fi
}

# $_RUNROOT / $_SYSTEMCTL — the two seams the start helpers below are
# parameterised on. Those bodies are byte-identical across the four inner
# installers and pinned that way (tools/prefix-gate-drift.test.sh), so anything
# that legitimately differs between them has to be a variable read by the body,
# never an edit to the body — and never a wrapper at the call site either, since
# `$_RUNROOT cmd` with _RUNROOT=run_root expands to a function call and a call
# site cannot reach inside the helper's own launchctl/systemctl invocations.
#
# This installer refuses to run as anything but root (the is_root gate further
# down, which exits 1 before a single binary is placed), so there is nothing to
# elevate through: the prefix is empty and `$_RUNROOT launchctl …` expands to
# `launchctl …`. It declares no $SYSTEMCTL seam either.
_RUNROOT=""
_SYSTEMCTL="systemctl"

# start_unit_darwin <label> <plist> — start a launchd system unit and verify it
# took. bootstrap's codes 5 (already loaded) and 37 are benign races against an
# async bootout — every other code is a real failure and must not be swallowed.
# enable + kickstart ALWAYS run: a bootstrap that no-ops on an already-loaded
# label still needs both.
#
# The status is captured with `|| _rc=$?`, NOT inside `if ! ...`: POSIX makes $?
# the NEGATED status of a `!` pipeline, so an `if !` branch would read 0 for
# every failure and tolerate nothing.
#
# EVERY launchctl CALL GOES THROUGH $_RUNROOT, and that is not decoration. Only
# one of the four scripts carrying this body refuses to run as anything but
# root; the other three are entered by an unprivileged shell and elevate per
# command. Unprivileged on macOS, `launchctl bootstrap` exits 5 — a code the
# case below TOLERATES as "already loaded" — and `launchctl print` exits 113, so
# a bare-launchctl body would sail past the guard, have enable and kickstart
# denied and swallowed, and then abort at the probe with the daemon already
# booted out by the caller. Silent non-elevation is the one failure this helper
# cannot see.
start_unit_darwin() {
    _label="$1"; _plist="$2"
    _rc=0
    $_RUNROOT launchctl bootstrap system "$_plist" 2>/dev/null || _rc=$?
    case "$_rc" in
        0 | 5 | 37) ;; # started / already loaded / async bootout still settling
        *)
            echo "error: launchctl bootstrap $_label failed (exit $_rc)" >&2
            echo "hint: sudo launchctl bootstrap system $_plist" >&2
            return 1
            ;;
    esac
    # enable + kickstart ALWAYS run, and their failures are deliberately funnelled
    # into the probe below rather than aborting under set -e: the probe is the only
    # thing that reports the label and a recovery command. `|| true` is safe here
    # ONLY because a verification immediately follows it — never widen it further.
    $_RUNROOT launchctl enable "system/$_label" 2>/dev/null || true
    $_RUNROOT launchctl kickstart -k "system/$_label" 2>/dev/null || true
    if $_RUNROOT launchctl print "system/$_label" >/dev/null 2>&1; then
        echo "launchd service $_label enabled + started"
    else
        echo "error: $_label did not come up after bootstrap" >&2
        echo "hint: sudo launchctl print system/$_label" >&2
        return 1
    fi
}

# start_unit_linux <unit> — enable, (re)start and verify a systemd system unit.
# The probe is the point: enable --now on a unit that then dies must not be
# reported as a started service.
#
# $_RUNROOT for the same reason as start_unit_darwin above; $_SYSTEMCTL because
# two of the four scripts carrying this body declare a $SYSTEMCTL test seam and
# still route every other systemctl call through it — a bare `systemctl` here
# would be the one call that escaped it.
start_unit_linux() {
    _unit="$1"
    # Failures here are funnelled into the is-active probe below rather than
    # aborting under set -e: the probe is the only thing that reports the unit and
    # a recovery command. `|| true` is safe here ONLY because a verification
    # immediately follows it — never widen it further.
    $_RUNROOT "$_SYSTEMCTL" enable --now "$_unit" 2>/dev/null || true
    $_RUNROOT "$_SYSTEMCTL" restart "$_unit" 2>/dev/null || true
    if $_RUNROOT "$_SYSTEMCTL" is-active --quiet "$_unit"; then
        echo "systemd service $_unit enabled + (re)started"
    else
        echo "error: $_unit is not active after enable --now" >&2
        echo "hint: sudo $_SYSTEMCTL status $_unit" >&2
        return 1
    fi
}

# binary_version_stamp <binary> — the version token a binary reports for ITSELF,
# or "" when it cannot be read.
#
# THIS, and not $BURROWEE_VERSION, is what the wait below compares against,
# because it is literally the same string the daemon writes: core's
# runtime_version.WriteRunning records the serve binary's `version` variable, and
# `<bin> version` prints that same variable as its first version-shaped token
# (the parse runtime_version.InstalledVersion does, in shell). $BURROWEE_VERSION
# is the release tag the bootstrap resolved, and it is empty whenever an operator
# runs an unpacked kit by hand.
#
# BURROWEE_DISPATCHER_VERSION is blanked for the probe, exactly as
# InstalledVersion strips it: inherited, the binary prints a dispatcher row
# FIRST, and the first token would be the dispatcher's stamp rather than this
# binary's.
binary_version_stamp() {
    # BOUNDED, because this runs the freshly-placed SERVE binary and an
    # unbounded `version` on a binary that hangs hangs the installer — with no
    # ceiling and no message, at the step whose whole job is to report. The Go
    # original of this probe (core runtime_version) bounds the same command at
    # 2s; this is that bound.
    #
    # THERE IS NO TIMEOUT HELPER IN THESE SCRIPTS TO REUSE, and acquiring a hard
    # dependency for one probe is the wrong trade — as is the shell-only
    # substitute, which cannot tell a finished child from a zombie and so pays
    # its ceiling on EVERY install. So the bound is applied where the host
    # already has it (`timeout`, GNU coreutils, present on every Linux host;
    # `gtimeout`, the same tool where a macOS host installed coreutils) and is
    # absent otherwise, leaving today's behaviour exactly as it is. A stock
    # macOS host is therefore still unbounded here — a known, stated gap, not an
    # oversight.
    _bvs_bound=""
    if command -v timeout >/dev/null 2>&1; then
        _bvs_bound="timeout 2"
    elif command -v gtimeout >/dev/null 2>&1; then
        _bvs_bound="gtimeout 2"
    fi
    # shellcheck disable=SC2020  # the repeated '\n' is deliberate: BOTH space and tab map to a newline.
    # shellcheck disable=SC2086  # $_bvs_bound is a command PREFIX and must word-split; empty means no bound.
    BURROWEE_DISPATCHER_VERSION="" $_bvs_bound "$1" version 2>/dev/null \
        | tr ' \t' '\n\n' \
        | grep -E '^v?[0-9]+(\.[0-9]+){0,5}(\.[0-9a-f]+)?$' \
        | head -n 1
}

# wait_for_running_version <running-json-dir> <expected-version> — block until
# the daemon reports it is serving <expected-version>, polling every
# $WAIT_INTERVAL seconds up to $WAIT_CEILING.
#
# running.json is written BY THE DAEMON at serve start (core
# runtime_version.WriteRunning) and carries {"version","pid","started_at"}, so a
# match is positive proof the NEW binary is the one serving. The installed-version
# marker is NOT usable as this predicate: THIS script writes it, so comparing it
# to the version being installed matches instantly — including on a host where
# the daemon never started, which is the only case worth asking about.
#
# The sed parse is deliberate, not laziness. running.json is json.Marshal of a
# flat three-field struct: no nesting, no indentation, and nothing escapable in a
# release stamp. An installer does not acquire a JSON dependency for that.
#
# BEST-EFFORT BY CONTRACT: a timeout warns and returns 1, and the caller ignores
# that status. "Did the unit come up at all" was already answered by
# start_unit_*, which fails the install. This is the softer second question — the
# unit is active, but is it serving the NEW binary? — and an operator whose
# daemon is slow to bind must not have a finished install fail retroactively.
wait_for_running_version() {
    _dir="$1"; _want="$2"; _waited=0
    while [ "$_waited" -lt "$WAIT_CEILING" ]; do
        _got="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            "$_dir/running.json" 2>/dev/null || true)"
        if [ -n "$_got" ] && [ "$_got" = "$_want" ]; then
            echo "daemon is serving $_want (after ${_waited}s)"
            return 0
        fi
        sleep "$WAIT_INTERVAL"
        _waited=$((_waited + WAIT_INTERVAL))
        echo "  waiting for the daemon to report $_want … ${_waited}s/${WAIT_CEILING}s"
    done
    echo "warning: the daemon did not report version $_want within ${WAIT_CEILING}s" >&2
    echo "hint: it may still be starting; 'doctor' below reports the live state" >&2
    return 1
}

# setup_root_service — render BOTH managed SYSTEM service units for the host init
# system and (re)load BOTH of them: the serve unit always, the updater unit
# unless BURROWEE_NO_UPDATER is set. Root-only caller. Renders unit FILES
# pointing at $SYS_BIN_DIR; it never places binaries, so it is safe to call from
# the units-only reinstall path as well as fresh install / update.
setup_root_service() {
    if [ "$(uname -s)" = "Darwin" ]; then
        # ── macOS: root LaunchDaemon ──────────────────────────────────────────
        # HOME=$ROOT_HOME (/var/root) so the daemon's os.UserHomeDir() resolves
        # $ROOT_HOME/.burrowee/edge — launchd daemons get no HOME by default
        # (mirrors the systemd unit's Environment=HOME=/root).
        # KeepAlive.PathState (matching core/setup's system units, which land on
        # the SAME paths): the update-restart rung SIGTERMs the running daemon
        # and relies on the supervisor respawning it after a CLEAN exit —
        # SuccessfulExit=false would leave a cleanly-exited daemon down.
        cat > "$LAUNCHD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LAUNCHD_LABEL</string>
  <key>ProgramArguments</key><array><string>$SYS_BIN_DIR/burrowee-edge</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>PathState</key><dict><key>$SYS_BIN_DIR/burrowee-edge</key><true/></dict></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>EnvironmentVariables</key><dict><key>HOME</key><string>$ROOT_HOME</string></dict>
</dict></plist>
EOF
        chmod 0644 "$LAUNCHD_PLIST"
        echo "wrote LaunchDaemon → $LAUNCHD_PLIST"

        # Updater LaunchDaemon (mirrors the systemd updater unit; HOME so its
        # console.json + identity resolve under $ROOT_HOME/.burrowee/edge).
        # Started below unless BURROWEE_NO_UPDATER is set — the auto-updater is
        # opt-OUT: an install leaves it running so the host keeps receiving fixes.
        cat > "$LAUNCHD_UPDATER_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LAUNCHD_UPDATER_LABEL</string>
  <key>ProgramArguments</key><array><string>$SYS_BIN_DIR/burrowee-edge-updater</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>PathState</key><dict><key>$SYS_BIN_DIR/burrowee-edge-updater</key><true/></dict></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>EnvironmentVariables</key><dict><key>HOME</key><string>$ROOT_HOME</string></dict>
</dict></plist>
EOF
        chmod 0644 "$LAUNCHD_UPDATER_PLIST"
        echo "wrote LaunchDaemon → $LAUNCHD_UPDATER_PLIST"

        # Migrate away the pre-rename org.burrowee.* units before loading the
        # com.burrowee.* ones — two labels must never run the same daemon.
        remove_legacy_launchd_units

        launchctl bootout "system/$LAUNCHD_LABEL" 2>/dev/null || true
        start_unit_darwin "$LAUNCHD_LABEL" "$LAUNCHD_PLIST"
        # Reached only when the serve unit verified up: start_unit_darwin returns
        # non-zero otherwise, and under `set -e` that ends this script. The flag
        # is therefore the honest answer to "is there a daemon to wait for", and
        # it is the ONLY thing that arms the post-start wait at the tail.
        SERVE_UNIT_STARTED=1

        # The updater starts with the serve unit — it is the only automatic
        # delivery channel, so an install that leaves it down leaves the host
        # unreachable by fixes. BURROWEE_NO_UPDATER=1 stages the unit without
        # starting it, for an owner who pins deliberately. A reinstall restarts
        # it either way, so a stale updater cannot keep running old code and
        # deadlock future pushes; the updater's own push path runs update.sh, not
        # this installer, so this can never self-kill.
        if [ -n "${BURROWEE_NO_UPDATER:-}" ]; then
            echo "note: BURROWEE_NO_UPDATER set — updater unit staged, not started" >&2
        else
            launchctl bootout "system/$LAUNCHD_UPDATER_LABEL" 2>/dev/null || true
            start_unit_darwin "$LAUNCHD_UPDATER_LABEL" "$LAUNCHD_UPDATER_PLIST"
        fi
    else
        # ── Linux: systemd system unit ([Service] mirrors the relay unit) ─────
        # HOME=/root so the daemon's os.UserHomeDir() resolves /root/.burrowee/edge
        # (a root system service has no HOME otherwise).
        # Restart=always (matching core/setup's system units, which land on the
        # SAME paths): the update-restart rung SIGTERMs the running daemon and
        # relies on systemd respawning it after a CLEAN exit — on-failure would
        # leave a cleanly-exited daemon down.
        mkdir -p "$(dirname "$SYSTEMD_UNIT")"
        cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=burrowee edge (self-hosted relay-edge)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=/root
ExecStart=$SYS_BIN_DIR/burrowee-edge run
Restart=always
RestartSec=2
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
        chmod 0644 "$SYSTEMD_UNIT"
        echo "wrote systemd unit → $SYSTEMD_UNIT"

        # Updater system unit ([Service] mirrors the serve unit; HOME=/root so its
        # console.json + identity resolve to /root/.burrowee/edge). Started below
        # unless BURROWEE_NO_UPDATER is set — the auto-updater is opt-OUT: an
        # install leaves it running so the host keeps receiving fixes.
        cat > "$SYSTEMD_UPDATER_UNIT" <<EOF
[Unit]
Description=burrowee edge updater
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=/root
ExecStart=$SYS_BIN_DIR/burrowee-edge-updater run
Restart=always
RestartSec=2
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
        chmod 0644 "$SYSTEMD_UPDATER_UNIT"
        echo "wrote systemd unit → $SYSTEMD_UPDATER_UNIT"

        systemctl daemon-reload
        start_unit_linux burrowee-edge
        # See the Darwin branch: reached only on a verified start, and the only
        # thing that arms the post-start wait.
        SERVE_UNIT_STARTED=1

        # The updater starts with the serve unit — it is the only automatic
        # delivery channel, so an install that leaves it down leaves the host
        # unreachable by fixes. BURROWEE_NO_UPDATER=1 stages the unit without
        # starting it, for an owner who pins deliberately. A reinstall restarts
        # it either way, so a stale updater cannot keep running old code and
        # deadlock future pushes; the updater's own push path runs update.sh, not
        # this installer, so this can never self-kill.
        if [ -n "${BURROWEE_NO_UPDATER:-}" ]; then
            echo "note: BURROWEE_NO_UPDATER set — updater unit staged, not started" >&2
        else
            start_unit_linux burrowee-edge-updater
        fi
    fi
}

# Test seam: when sourced with this var set, stop here so a test harness can call
# the functions above without any install side-effect (tools/test-config-migrate.sh).
# shellcheck disable=SC2317  # the `|| exit 0` IS reached when this script is run (not sourced)
if [ -n "${BURROWEE_INSTALLER_SOURCE_ONLY:-}" ]; then return 0 2>/dev/null || exit 0; fi

# ---------------------------------------------------------------------------
# ROOT IS REQUIRED, and refused here — still before anything is placed, and
# before every mode below, because every one of them writes somewhere only root
# may write: /usr/local/burrowee, /etc/systemd/system, /Library/LaunchDaemons.
#
# The alternative is worse than an error. /usr/local is group-writable on an
# Intel Mac with Homebrew, so an unprivileged run would place the binaries, fail
# at the first unit write, and leave a half-installed edge with no service — and
# the binaries it did place would sit in a directory a non-root user can rewrite,
# which is exactly the standing uid-0 grant the root-owned destination exists to
# close.
#
# The refusal comes AFTER the source-only seam above: sourcing this file defines
# functions and places nothing, and tools/test-config-migrate.sh drives them as
# an ordinary user.
# ---------------------------------------------------------------------------
if ! is_root; then
    echo "install: this installer must run as root — it installs to /usr/local/burrowee/bin and" >&2
    echo "install: manages a system service (systemd unit / launchd LaunchDaemon)." >&2
    echo "install: as of edge 0.2.0 there is no per-user install; nothing has been installed." >&2
    echo "install: the published installer elevates on its own — you are seeing this" >&2
    echo "install: because you ran an unpacked kit directly. Either:" >&2
    echo "hint:   sudo sh ./install.sh                                   # this kit" >&2
    echo "hint:   curl -fsSL https://release.burrowee.com/$COMP/install.sh | sh   # the channel" >&2
    exit 1
fi

# The whole machine-owned tree, before anything is placed and before the
# ladder is asked about it. Deliberately AFTER the source-only seam above:
# sourcing this file defines functions and creates nothing, which is what lets
# tools/test-config-migrate.sh drive them as an ordinary user.
# ensure_system_tree is called below, AFTER the uninstall branch: an uninstall
# must neither create the 0.3 tree on a 0.2 host nor be refused by a tree
# assertion — the 0.2 edge had no such step and its removal path must survive.

# ---------------------------------------------------------------------------
# Units-only mode (BURROWEE_UNITS_ONLY=1): the offline reinstall entrypoint run
# by edge's LocalReinstall. Re-render + reload the managed service units WITHOUT
# placing binaries or touching the network.
# ---------------------------------------------------------------------------
if [ -n "${BURROWEE_UNITS_ONLY:-}" ]; then
    ensure_system_tree
    setup_root_service
    # The updater track reaches 0.3 through here (LocalReinstall), never through
    # the full path below: the ladder it ran earlier found the 0.2 units still
    # naming /usr/local/bin/<name> and correctly kept every copy, so the links
    # and the exec-root sweep have to happen here, after the units moved.
    link_operator_bins
    sweep_stale_exec_root
    echo "edge units-only reinstall: service units re-rendered + reloaded."
    exit 0
fi

if [ -n "${BURROWEE_UNINSTALL:-}" ]; then
    # Unconditional, like every other mode: there is one install shape left, and
    # it always has the managed system service.
    if [ "$(uname -s)" = "Darwin" ]; then
        launchctl bootout "system/$LAUNCHD_LABEL" 2>/dev/null || true
        launchctl bootout "system/$LAUNCHD_UPDATER_LABEL" 2>/dev/null || true
        rm -f "$LAUNCHD_PLIST" "$LAUNCHD_UPDATER_PLIST"
        remove_legacy_launchd_units
    else
        systemctl disable --now burrowee-edge 2>/dev/null || true
        systemctl disable --now burrowee-edge-updater 2>/dev/null || true
        rm -f "$SYSTEMD_UNIT" "$SYSTEMD_UPDATER_UNIT"
        systemctl daemon-reload 2>/dev/null || true
    fi
    removed=""
    for b in $BINS; do
        case "$b" in burrowee) continue ;; esac
        rm -f "$BIN_DIR/$b"
        removed="$removed $b"
    done
    # The bare `burrowee` dispatcher is SHARED across co-installed components
    # (e.g. a relay on the same host) — remove it only when no other
    # burrowee-* binary remains in $BIN_DIR.
    if ls "$BIN_DIR"/burrowee-* >/dev/null 2>&1; then
        echo "kept $BIN_DIR/burrowee (dispatcher) — other burrowee components remain installed"
    else
        rm -f "$BIN_DIR/burrowee"
        removed="$removed burrowee"
    fi
    # The operator-typed links, and only the ones that still point into
    # $BIN_DIR (spec §6.1 rule 4). The shared `burrowee` link goes with the
    # dispatcher itself: it is removed only when the binary it points at was.
    unlink_operator_bins
    echo "removed from $BIN_DIR:$removed"
    exit 0
fi

ensure_system_tree

for b in $BINS; do
    [ -f "./$b" ] || { echo "missing $b in archive" >&2; exit 1; }
    # -m 0755 stated, never cp -p: the payload's recorded mode is not ours.
    install -m 0755 "./$b" "$BIN_DIR/$b"
    if [ "$(uname -s)" = "Darwin" ]; then
        xattr -d com.apple.quarantine "$BIN_DIR/$b" 2>/dev/null || true
    fi
done
echo "installed to $BIN_DIR: $BINS"

# ---- state migrations -------------------------------------------------------
# Unconditional and a no-op unless a rung applies. See run_migration_ladder for
# why it sits exactly here: after the binaries, before the version anchor.
run_migration_ladder

# ---- cover assets (decoy pages for handleCover file mode) -------------------
# Always refresh the two SHIPPED defaults (admin.html + default.html) on every
# install/update: a stale hardcoded footer blows the decoy, so the shipped covers
# must track the release. Operator-added per-host <host>.html covers are not
# enumerated here, so they survive untouched (and still win in selectCover).
# The DATA root: a cover page is shipped content the installer re-places on
# every run, not something an operator reconstructs.
if [ -d "./covers" ]; then
    mkdir -p "$COMP_DATA/covers"
    for cf in admin.html default.html; do
        [ -f "./covers/$cf" ] || continue
        install -m 0644 "./covers/$cf" "$COMP_DATA/covers/$cf" 2>/dev/null \
            || cp "./covers/$cf" "$COMP_DATA/covers/$cf" 2>/dev/null \
            || echo "warning: could not install cover $cf" >&2
    done
fi

"$BIN_DIR/burrowee" --version 2>/dev/null || true

# ---- version-gated config migration ---------------------------------------
# Roll new default config onto existing installs (seed-if-absent), gated by the
# prior installed version. Best-effort; never aborts the install/update.
#
# $VERSION_MARKER is ALSO the migration ladder's anchor (migrations/run.sh reads
# it as $COMP_HOME/installed-version), which is why the write is withheld when a
# rung ran and could not be recorded: the receipt and the anchor are the two
# gates on a rung, and recording the version with the receipt lost closes the
# last one on work nothing can prove finished.
if [ -n "${BURROWEE_VERSION:-}" ]; then
    OLD_VER=""
    [ -f "$VERSION_MARKER" ] && OLD_VER="$(cat "$VERSION_MARKER" 2>/dev/null || true)"
    migrate_config "$OLD_VER" || echo "warning: config migration step failed; continuing" >&2
    mkdir -p "$COMP_HOME" 2>/dev/null || true
    if [ "$MIGRATE_UNRECORDED" = 1 ]; then
        report_unrecorded_migration
    elif printf '%s\n' "$BURROWEE_VERSION" > "$VERSION_MARKER.tmp" 2>/dev/null; then
        mv -f "$VERSION_MARKER.tmp" "$VERSION_MARKER" 2>/dev/null || echo "warning: could not record installed version" >&2
    else
        echo "warning: could not write version marker" >&2
    fi
fi

# Self-copy: keep a copy of this installer at $COMP_HOME/install.sh so an offline
# units-only reinstall (BURROWEE_UNITS_ONLY=1, run by edge's LocalReinstall) can
# re-render + reload the service units without a fresh download.
#
# THE MIGRATIONS GO WITH IT. This script resolves the runner and the sweep
# library relative to its OWN path, so a $COMP_HOME holding install.sh without
# migrations/ is an installer that silently cannot migrate and silently stops
# sweeping — both of which look exactly like a clean run.
mkdir -p "$COMP_HOME" 2>/dev/null || true
cp "$0" "$COMP_HOME/install.sh" 2>/dev/null || true
if [ -n "$MIGRATIONS_DIR" ] && [ "$MIGRATIONS_DIR" != "$COMP_HOME/migrations" ]; then
    mkdir -p "$COMP_HOME/migrations" 2>/dev/null || true
    cp "$MIGRATIONS_DIR"/* "$COMP_HOME/migrations/" 2>/dev/null \
        || echo "note: could not keep a copy of migrations/ at $COMP_HOME — a later" >&2
fi

# ---- the managed system service --------------------------------------------
# Every install sets up the managed root service running `burrowee-edge run` and
# (re)starts it, so the same one-liner is a fresh install AND an in-place update.
# There is no other install shape to fall through to: an unprivileged run was
# refused at the top, with nothing placed.
setup_root_service
# The links come AFTER the units: link_operator_bins replaces
# $LINK_DIR/burrowee-edge in place (rm -f, ln -sfn), and until setup_root_service
# has re-rendered and reloaded the units they still name that exact path — on
# macOS a KeepAlive.PathState job can observe the unlink and bounce the running
# daemon onto the new binary before the 0.3 unit exists. Now the loaded units
# name $SYS_BIN_DIR, so nothing running watches the link.
link_operator_bins
# Only now: the binaries are in $SYS_BIN_DIR and the units naming them are
# not merely written but loaded. Deliberately NOT in BURROWEE_UNITS_ONLY
# mode above — that path places no binaries at all, so the precondition
# this sweep's safety rests on ("the new copies are already in place") is
# not something that mode establishes.
sweep_stale_user_bins
sweep_stale_exec_root
"$SYS_BIN_DIR/burrowee-edge" version 2>/dev/null || true
echo "edge system install complete."
# The managed service runs the daemon; pairing is a separate operator step:
#   burrowee edge cli bootstrap <blob> <pin>   (or via the console)
if [ ! -d "$COMP_HOME/identity" ] && [ ! -f "$COMP_HOME/console.json" ]; then
    # A host converging off the pre-collapse per-user layout may already own an
    # identity — under the operator's home, which this daemon does not read.
    note_orphaned_user_state
    echo "next: pair this edge — burrowee edge cli bootstrap <blob> <pin>"
fi

# ---------------------------------------------------------------------------
# Prove the NEW daemon is serving, then report — the last thing this script does
# on the full-install path, because "hands back" is where the claim is made.
#
# THE PATH. burrowee-edge writes running.json into the DATA tree, not the config
# tree: cmd/burrowee-edge/config.go's recordRunningVersion is
# runtime_version.WriteRunning(edgeData(), version), and edgeData() is
# edgeroot.DataDirFor(edgeHome()) — $COMP_DATA here, never $COMP_HOME. That
# function is named rather than inlined for exactly this reason, and its header
# records what the second spelling cost: a doctor reporting "the daemon is not
# running" about a daemon that was, for 35h on a production node. These two names
# must stay in step; tools/install-waits-for-daemon.test.sh asserts they do.
#
# Not on the BURROWEE_UNITS_ONLY path above: that mode places no binaries, so
# there is no version being installed to wait for.
# ---------------------------------------------------------------------------
if [ "$SERVE_UNIT_STARTED" = 1 ]; then
    WANT_VERSION="$(binary_version_stamp "$SYS_BIN_DIR/burrowee-edge")"
    if [ -n "$WANT_VERSION" ]; then
        # The timeout's status is deliberately dropped: this wait never fails an
        # install (see wait_for_running_version's contract).
        wait_for_running_version "$COMP_DATA" "$WANT_VERSION" || true
    else
        echo "note: could not read the installed binary's version stamp — not waiting" >&2
    fi
else
    echo "note: the serve unit was not (re)started by this run — not waiting on it"
fi

# ---- doctor, unconditionally ------------------------------------------------
# On the match path, the timeout path and the skipped path alike. The wait
# answers one bit; doctor is the report an operator acts on, and after a timeout
# it is the only thing that says what the daemon is actually doing.
#
# ITS EXIT STATUS IS NOT THIS INSTALL'S. The verdict was decided by start_unit_*
# further up; a read-only `doctor` exits 3 when it finds failing rows, which is a
# diagnostic doing its job and not a failed install. Hence the guard.
#
# STDIN IS /dev/null so it can neither prompt nor elevate. doctor's elevation
# gate is `euid != 0 && stdin is a terminal` (mayElevateFn,
# cmd/burrowee-edge-cli/doctor_elevate.go), and a non-terminal stdin makes it
# false whoever is running — this script is already root, but the redirect is
# what makes that structural rather than incidental. Only `--fix` remediates or
# prompts, and this is the read-only verb.
"$SYS_BIN_DIR/burrowee-edge-cli" doctor < /dev/null || true

#!/bin/sh
# Burrowee inner installer — gateway (POSIX sh).
#
# Ships at the ROOT of the verified release zip as `install.sh`. The outer
# bootstrap verifies the zip (minisign + sha256) and ONLY THEN execs this with
# cwd = the unzipped dir, so the binaries sit alongside this script. It installs
# them into $BIN_DIR — @ROOT@/bin, root-owned, ALWAYS — with the
# placement elevated via run_root the same way a root-owned tree always required. As of
# 0.2.0 there is no per-user prefix flow at all: a PREFIX that would MISDIRECT
# the install is REFUSED, loudly (see below), never silently redirected — while
# one that merely names this same destination is honoured and then cleared. Set
# BURROWEE_UNINSTALL to remove them
# instead. Set BURROWEE_UNITS_ONLY=1 to write+load both service units without
# touching binaries or running bootstrap. Set BURROWEE_UPDATE=1 to run update
# mode: per-binary sha256 change detection, transactional swap, and a final
# BURROWEE_CHANGED=<names> line. In update mode, BURROWEE_FORCE=1 bypasses the
# sha256 check and re-places every serve binary (the `--force` full-reinstall
# path — the diff would otherwise skip an identical version).
#
# Service model: the service units are SYSTEM-level and the daemon they start
# runs as ROOT, so the gateway starts at boot without a GUI login:
# /Library/LaunchDaemons on macOS, /etc/systemd/system on Linux. Its config and
# data live under the SYSTEM roots ($SYS_CONFIG_DIR / $SYS_DATA_DIR), named
# explicitly in the unit rather than left to resolve from whoever's environment
# the daemon happens to inherit. System steps run via sudo (prompting on the
# controlling tty; with no tty and no cached credentials the unit step aborts
# with guidance).
#
# ONE BINARY LOCATION, INSIDE ONE MACHINE-OWNED TREE. Every binary, including
# the ones something running AS ROOT execs with nobody watching (the daemon,
# the console child it spawns, the updater agent, the cli the migration shells
# to), lands in $BIN_DIR — the same directory this script and its migrations/
# are kept in too — and $BIN_DIR is one of three siblings under
# @ROOT@: bin/ (the execution surface), etc/gateway (config, the
# identity) and var/gateway (state). This script CREATES that tree, root-owned,
# with every level's owner and mode stated (ensure_system_tree), and asserts
# what it built before a unit may name any of it (assert_system_tree).
#
# HOW IT GOT HERE. The binaries used to live in two directories: a per-user
# $BIN_DIR and a root-owned $LIBEXEC_DIR, kept apart because $BIN_DIR's default
# was $HOME/.local/bin, and a root unit naming a per-user path is a permanent
# uid-0 grant to that user. 0.2.0 collapsed them into /usr/local/bin on the
# argument that a root-owned /usr/local/bin passes the identical root-secure
# ancestor walk the separate tree existed to guarantee. THAT PREMISE IS FALSE
# wherever Homebrew owns /usr/local/bin — on an Intel Mac brew creates and
# chowns /usr/local/{bin,etc,var} to the console user long before @DISPATCHER@ is
# installed, and 0.2's three independent roots then had two answers of "no" to
# "is my state root-owned", with no way forward that did not take a directory
# away from the package manager. 0.3 moves the exec root WITH the config/data
# pair into one tree @DISPATCHER@ creates beside Homebrew's directories rather
# than inside them: that restores the guarantee the libexec split gave without
# restoring a second tree, because bin/ is inside the same tree as the state it
# operates on and one ancestor chain answers for all three. The retired
# /usr/local/libexec/burrowee/gateway is still left alone: never written, never
# removed — an operator's call, by hand.
#
# THE SURVIVING INVARIANT (ensure_root_exec_surface / verify_root_exec_surface,
# unchanged in kind): only a path that is root-owned and unwritable by non-root
# ALL THE WAY TO / may be named in a unit or execed by the root updater. On
# every host that walk passes through /usr/local, which is root:wheel 755 on
# macOS and root-owned on every Linux; what Homebrew chowns are its children,
# and @ROOT@ is not one of them.
#
# WHY THE DEFAULT MOVED AT ALL: something outside this component now execs
# `@DISPATCHER@` off PATH as root to find this gateway — a plain PATH binary a
# unprivileged user could otherwise overwrite is a standing uid-0 grant to
# whoever owns it, even though no @DISPATCHER@ UNIT ever execs it as root. A
# root-owned $BIN_DIR is what makes that PATH lookup safe to trust.
#
# WHY THE PER-USER FLOW IS GONE, not merely de-defaulted. The PREFIX branch did
# not only put binaries somewhere else: it switched OFF the entire privileged
# surface — ensure_root_exec_surface, render_units, load_units,
# migrate_from_legacy and record_installed_version all gated on it — and the
# outer bootstrap defaulted PREFIX to $HOME/.local on every `curl … | sh`, so
# that branch was not the exception, it was the only path anyone took.
# Observed on a production node, 2026-08-13: @DISPATCHER@ sat at
# /home/ubuntu/.local/bin/burrowee while a consumer's ROOT daemon resolved the
# absolute /usr/local/bin/burrowee — correctly, since its unit pins
# PATH=/usr/bin:/bin:/usr/sbin:/sbin and a PATH lookup can reach nothing else.
# That daemon crash-looped 50 times on "resolve register socket" while
# `@DISPATCHER@ gateway doctor` reported a perfectly healthy gateway with 109h
# uptime. A component that installs where its consumers cannot look has not
# installed, however cleanly it exits.
#
# Removing the flow did not remove what it left behind, and the leftovers keep
# winning: $HOME/.local/bin precedes /usr/local/bin on a normal PATH. So an
# install now also sweeps the stale per-user copies of its own binaries, by
# exact name, after the units naming $BIN_DIR are loaded — sweep_stale_user_bins,
# which loads the sweep out of migrations/lib_stale_user_bins.sh, the one
# implementation the gateway's 0.2.0 ladder rung uses too.
#
# Because a root-scheme unit runs as nobody in particular, it records no owner
# and the single system slot is free for any installer to replace. Only a
# LEGACY per-user unit (one that still carries UserName / User=) is owned, and
# replacing another user's needs consent — a /dev/tty prompt, or
# BURROWEE_FORCE_SERVICE_OVERRIDE=1 when non-interactive.
#
# The unit body must stay byte-identical to what the gateway's own renderer
# emits (internal/gateway/service_install.go: LaunchdPlist / SystemdUnit and
# their updater twins). Both writers rewrite whenever content differs and then
# reload, so any divergence here does not merely disagree — it makes the two
# writers fight, booting the daemon out on every refresh.
set -eu

# ONE DESTINATION, decided here and nowhere else: @ROOT@/bin,
# root-owned — the exec root of the machine-owned tree (see the header).
# There is no branch left to take — every step below that treats $BIN_DIR as the
# privileged surface (ensure_root_exec_surface, render_units, load_units,
# migrate_from_legacy, record_installed_version) now runs on EVERY install,
# because there is no longer an install shape for which it would be wrong.
#
# BURROWEE_BIN_DIR is the surviving TEST-ONLY seam, and the only one: it
# redirects this destination so the suite never writes into the real
# @ROOT@. Never set it on a real host — nothing about the
# install's meaning changes when it is set, which is exactly why it is safe for
# tests and useless as a user-facing knob. It must end in `bin`: $SYSTEM_ROOT
# below is its parent, and the migration runner round-trips PREFIX=<that
# parent> back through "${PREFIX}/bin".
#
# Resolved BEFORE the PREFIX gate below, because the gate's whole question is
# "does this PREFIX name the destination we would have picked anyway?" — it
# cannot ask that without $BIN_DIR. This is an assignment only: nothing is
# created, placed or written until well after the gate.
BIN_DIR="${BURROWEE_BIN_DIR:-@ROOT@/bin}"

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

# A DIVERGENT PREFIX IS REFUSED — a PREFIX that names THIS destination is not.
#
# Refusing the divergent one is the point: an operator who typed
# PREFIX=$HOME/.local and got a root-owned /usr/local/bin would be handed exactly
# the class of surprise this collapse exists to remove, one direction reversed.
# They get told instead, and the process that set it (a shell profile, an outer
# bootstrap, a wrapper) is the thing that has to change.
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
        # downstream can read it as a fallback.
        #
        # migrate_from_legacy is the one place downstream that cares, and it is
        # safe for a reason SPECIFIC TO THIS FILE: it RE-SETS PREFIX on the
        # invocation line ("PREFIX=$(dirname "$BIN_DIR") … sh $_runner"), so an
        # inherited value is overridden rather than out-competed. That makes the
        # clearing belt-and-braces THERE and load-bearing everywhere else: the
        # `VAR=x sh run.sh` form ADDS to the environment rather than replacing
        # it, so any rung or helper that reads
        # BIN_DIR="${BIN_DIR:-${PREFIX:-/usr/local}/bin}" without being handed an
        # explicit override would otherwise see the operator's prefix. Cleared,
        # never set to "": absent, not empty, as core does it.
        unset PREFIX
    else
        # The refusal carries BOTH spellings of the destination: the literal
        # @ROOT@/bin (production truth, and what the suite's static
        # pins check) and the resolved $_true_bin. They differ only when the
        # BURROWEE_BIN_DIR test seam is set, and an operator reading a refusal on
        # a real host must see the real path either way.
        #
        # printf, not echo, on the two lines that interpolate caller-controlled
        # text: a PREFIX containing a backslash escape ('\c' ends echo's output
        # in dash) would otherwise truncate the refusal at the moment it quotes
        # the offending value, hiding the component, the destination and the
        # "nothing has been installed" line all at once.
        printf '%s\n' "install: PREFIX is set to '$PREFIX', but as of gateway 0.2.0 this installer" >&2
        echo "install: has one destination: @ROOT@/bin, root-owned. The per-user" >&2
        echo "install: prefix flow is gone — the gateway's service units run as root and name" >&2
        echo "install: the binaries absolutely, and other components resolve" >&2
        echo "install: @ROOT@/bin/burrowee by absolute path, so a per-user copy" >&2
        echo "install: is invisible to both." >&2
        printf '%s\n' "install: (a PREFIX resolving to $_true_bin is honoured; '$_prefix_bin' is not it.)" >&2
        echo "hint: unset PREFIX and re-run; nothing has been installed." >&2
        exit 1
    fi
    unset _prefix_bin _true_bin
fi
BINS="@DISPATCHER@ burrowee-gateway burrowee-gateway-cli burrowee-gateway-console burrowee-register burrowee-gateway-updater"
# OPERATOR_BINS — the subset of $BINS an OPERATOR TYPES. Deliberately smaller
# than $BINS: burrowee-gateway-console and burrowee-gateway-updater are spawned
# by a root parent that names the real path, and burrowee-register is execed by
# the dispatcher the same way — nothing a human types. It has ONE consumer
# left, the stale-exec-root sweep: these are the names a 0.2 install left as
# real files in /usr/local/bin, and the ones an operator's PATH finds there
# ahead of $BIN_DIR. The sweep runs from the guard after the verified restart
# (sweep_stale_exec_root), because a unit still naming one of them is refused
# by the library until the units move.
#
# IT WAS CALLED LINK_BINS, and the rename is the point: nothing is symlinked
# anywhere any more (see the block where link_operator_bins used to be). A list
# still named for a step that no longer exists is how the step gets re-added by
# someone who reads the name as a promise.
OPERATOR_BINS="@DISPATCHER@ burrowee-gateway burrowee-gateway-cli"
# The 0.2 exec root the sweep reads. BURROWEE_LEGACY_BIN_DIR is a TEST-ONLY
# seam like BURROWEE_BIN_DIR, and it is LOAD-BEARING: a sandboxed run must
# never iterate the real /usr/local/bin of the host it runs on (this
# workstation is a live 0.2 host). It used to chain through BURROWEE_LINK_DIR,
# which is gone with the link step — a test still setting only the old seam
# would sweep the developer's own machine.
LEGACY_BIN_DIR="${LEGACY_BIN_DIR:-${BURROWEE_LEGACY_BIN_DIR:-/usr/local/bin}}"
COMP=gateway
GW_HOME="$HOME/.burrowee/gateway"
# The per-user component tree. Identical to $GW_HOME for this component, spelled
# separately because the first-run bootstrap probe at the bottom is written in
# terms of "this component's home" and reads better that way.
COMP_HOME="$HOME/.burrowee/$COMP"
# The invoking user. No longer rendered into any unit (the daemon runs as root)
# — it is only compared against the owner a LEGACY per-user unit still records,
# to decide whether taking over the slot needs consent.
SERVICE_USER="$(id -un)"
# System unit locations. The BURROWEE_*_DIR overrides are test seams for the
# sandboxed installer harness — never set them in production.
LAUNCHD_DIR="${BURROWEE_LAUNCHD_DIR:-/Library/LaunchDaemons}"
SYSTEMD_DIR="${BURROWEE_SYSTEMD_DIR:-/etc/systemd/system}"
# The root daemon's config and data roots — the same two constants the Go side
# resolves through core's system_root (ConfigRoot/DataRoot + "gateway"). They
# are written into the units, so they must not drift from that pair. Same
# test-seam caveat as above.
SYS_CONFIG_DIR="${BURROWEE_SYSTEM_CONFIG_DIR:-@ROOT@/etc/gateway}"
SYS_DATA_DIR="${BURROWEE_SYSTEM_DATA_DIR:-@ROOT@/var/gateway}"
SYS_LOG_DIR="$SYS_DATA_DIR/logs"
# THE TREE ABOVE THE THREE ROOTS. In production all three parents are the one
# directory @ROOT@, and the two intermediate levels are its etc/
# and var/. They are DERIVED from the three seamed leaves rather than spelled
# as a fourth seam so that a sandboxed run can never reach outside its
# sandbox: a suite that redirects $BIN_DIR to <tmp>/bin has, by construction,
# redirected the tree to <tmp> as well, and a seam it forgot to set would
# otherwise default to the real @ROOT@ — which on a Homebrew Mac
# a pass-through `sudo` stub could actually create. Nothing above
# $SYSTEM_ROOT is ever created or re-moded by this script (ensure_dir_stated
# refuses a level whose parent is absent): /usr/local is not ours.
SYSTEM_ROOT="$(dirname "$BIN_DIR")"
SYS_ETC_ROOT="$(dirname "$SYS_CONFIG_DIR")"
SYS_VAR_ROOT="$(dirname "$SYS_DATA_DIR")"

# ---------------------------------------------------------------------------
# UNREACHABLE FROM EVERY MODE, AND KEPT ON PURPOSE — read this before deleting
# any of it.
#
# WAIT_INTERVAL, WAIT_CEILING, SERVE_UNIT_STARTED, binary_version_stamp and
# wait_for_running_version below are no longer called by the default mode:
# Task 7 moved the restart (and therefore the wait that follows it) into
# guard.sh, and SERVE_UNIT_STARTED is now set twice and read nowhere on this
# component.
#
# BURROWEE_UNITS_ONLY USED TO BE THE ONE MODE THAT STILL REACHED THEM, through
# load_units, and it no longer does: `service install` and `doctor --fix` are
# operator verbs typed in a session that is routinely tunnelled through the
# gateway they restart, so that mode hands its restart to the guard exactly as
# the fresh path does. The whole chain went unreachable with it —
# load_units, start_unit_darwin, start_unit_linux, UPDATER_START_FAILED and
# finish_with_updater_verdict included. NONE of it is dead weight to be swept
# up in a later tidy:
#
#   * start_unit_darwin() and start_unit_linux() are pinned BYTE-IDENTICAL
#     across four files by tools/prefix-gate-drift.test.sh, and load_units is
#     gateway's only caller of them — deleting it leaves two functions nothing
#     in this file references, which is the state a future reader deletes.
#   * tools/install-no-bootout.test.sh requires a literal `kickstart -k` in
#     this file, so that its "the installer never boots the serve label out"
#     check cannot pass vacuously on a file that simply stopped starting the
#     service. That literal lives in start_unit_darwin.
#   * edge and relay still restart synchronously through the identical block.
#     Gateway's copy is what the drift pins compare theirs against.
#
# So the correct reading of this whole region is "the shared shape, retained
# for the pins, executed by the other components" — not "gateway code with no
# caller". Removing it is a four-file change with its own brief, not a
# side-effect of a gateway task.
#
# They stay ALSO because this block is DRIFT-PINNED BYTE-FOR-BYTE against
# inner/edge/install.sh by tools/install-waits-for-daemon.test.sh (its sections
# 2 and 6): edge still waits synchronously, the house idiom for shared
# install-time logic with no shared library is a duplicated block plus a pin,
# and deleting gateway's half would not simplify anything — it would delete the
# pin and let edge's copy drift unwatched. Anything inside the two extracted
# regions (from the "# The post-start daemon wait" line through
# `SERVE_UNIT_STARTED=0`, and from "# binary_version_stamp <binary>" through
# the close of wait_for_running_version) must therefore change in BOTH files or
# in neither — which is also why this note sits outside them.
# ---------------------------------------------------------------------------

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

# UPDATER_START_FAILED — the deferred verdict for a failed UPDATER start.
#
# A serve start that fails is fatal on the spot: the serve daemon IS the
# product, and everything after it is bookkeeping about a host that is not
# running. The updater is the delivery channel, and a fatal abort there cost
# strictly more than it bought — it skipped sweep_stale_user_bins,
# report_unrecorded_migration, record_installed_version and the first-run
# blob/PIN prompt, so the host ended with the NEW binaries on disk, the
# migration ladder's anchor still naming the OLD version, and a fresh gateway
# that was never offered enrollment. The next rung then gated on a version this
# host had already moved past.
#
# So the failure is recorded, the script finishes its state-recording work, the
# enrollment prompt still runs, doctor still reports, and the exit status is
# non-zero at the very end — see finish_with_updater_verdict.
#
# Deliberately NOT part of the WAIT_* block above: that block is byte-identical
# with edge's (tools/install-waits-for-daemon.test.sh pins it), and this flag is
# gateway's alone — edge writes its version marker BEFORE setup_root_service, so
# it has no anchor to strand.
UPDATER_START_FAILED=0
# THE PRIVILEGED EXECUTION SURFACE, $BIN_DIR — the bin/ of the machine-owned
# tree, beside the config/data roots it serves (formerly a separate root-owned
# tree at /usr/local/libexec/burrowee/gateway, then briefly /usr/local/bin; see
# the header comment for why neither survived). A host that still carries the
# libexec tree keeps it, inert: nothing here ever writes to it again, and
# nothing here removes it either — that is an operator's call, by hand, not
# this script's.
#
# The binaries a ROOT process execs unattended, and therefore the ones that must
# come from a path no unprivileged user can rewrite (verify_root_exec_surface):
#   burrowee-gateway          the daemon named in the core unit
#   burrowee-gateway-console  spawned + supervised by that daemon, from its own dir
#   burrowee-gateway-updater  the daemon named in the updater unit
#   burrowee-gateway-cli      execed as root by migrations/v0_1_to_v0_2.sh, which the
#                             console-push path runs with no operator present
# @DISPATCHER@ and burrowee-register are NOT here: nothing running as root execs
# them. They now share $BIN_DIR with the four above regardless — the point of
# this list is which paths the root-secure walk gates BEFORE a unit may name
# them, not which directory they live in.
ROOT_BINS="burrowee-gateway burrowee-gateway-console burrowee-gateway-updater burrowee-gateway-cli"
# ROOT_BIN_PLACE_EXCLUDE names one entry of $ROOT_BINS that ensure_root_exec_surface
# must verify but never (re)PLACE from the bundle — set by BURROWEE_UPDATE mode to
# "burrowee-gateway-updater" before it calls migrate_from_legacy/render_units.
#
# THE COLLAPSE MADE THIS NECESSARY. Before it, ensure_root_exec_surface placed
# ROOT_BINS into the separate $LIBEXEC_DIR — never into $BIN_DIR, the one
# directory update mode's own BINS loop already excludes the updater from — so
# the two could never collide. Now that ensure_root_exec_surface places into
# $BIN_DIR too, calling it unconditionally from update mode's migrate_from_legacy
# would silently overwrite the running updater's own binary with whatever this
# bundle staged — exactly the hazard the BINS loop's own exclusion exists to
# prevent, reintroduced one function over. Verification still covers it
# (verify_root_exec_surface never reads this var): a unit is about to be
# rewritten either way, and it must still refuse to name a path that fails the
# walk, whether this run placed that path or an earlier one did.
ROOT_BIN_PLACE_EXCLUDE=""

# ---------------------------------------------------------------------------
# has_tty — whether a controlling terminal is available for prompts (stdin is
# usually the curl pipe, so probe /dev/tty as well).
# ---------------------------------------------------------------------------
has_tty() {
    [ -t 0 ] && return 0
    ( exec </dev/tty ) 2>/dev/null
}

# ---------------------------------------------------------------------------
# run_root — run a system-mutation command as root: directly when already
# root, via sudo (which prompts on the controlling tty) when interactive, via
# `sudo -n` otherwise. Returns non-zero with guidance when root cannot be
# obtained; under `set -e` that aborts unless the caller opts out with `|| …`.
# ---------------------------------------------------------------------------
run_root() {
    if [ "$(id -u)" = 0 ]; then "$@"; return; fi
    if has_tty; then sudo "$@"; return; fi
    if sudo -n "$@" 2>/dev/null; then return 0; fi
    echo "error: 'sudo $*' failed — no tty for a password prompt and no cached sudo credentials." >&2
    echo "hint: re-run from an interactive terminal, or pre-authorize with 'sudo -v', then retry ('@DISPATCHER@ gateway service install')." >&2
    return 1
}

# ---------------------------------------------------------------------------
# The privileged execution surface.
#
# have_real_root — whether elevation on this host actually yields uid 0.
#
# Everything below asserts OWNERSHIP, and ownership can only be asserted where
# root was genuinely obtained. The sandboxed installer harness supplies a
# pass-through `sudo` stub, so every file it "installs as root" is owned by the
# test user: asserting uid 0 there would refuse every test run for a reason that
# says nothing about a real host. Asking the elevation path who it is answers the
# question directly, and keeps the production assertion strict without a second
# env seam that nobody reading the code can see.
#
# Cached, because it costs a sudo round trip.
# ---------------------------------------------------------------------------
HAVE_REAL_ROOT=""
have_real_root() {
    if [ -z "$HAVE_REAL_ROOT" ]; then
        if [ "$(run_root id -u 2>/dev/null || echo -)" = 0 ]; then
            HAVE_REAL_ROOT=yes
        else
            HAVE_REAL_ROOT=no
        fi
    fi
    [ "$HAVE_REAL_ROOT" = yes ]
}

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
dir_is_root_secure() {
    _ds_d="$1"
    [ -d "$_ds_d" ] || return 3
    # Walk the RESOLVED directory, never the lexical spelling. stat does not
    # dereference a symlink and a macOS symlink is itself root-owned 0755, so a
    # /usr/local/bin -> /Users/x/bin link passes every check while the directory
    # a link would actually be written into is never examined — and root's own
    # links then land somewhere that user can rewrite.
    #
    # RESOLVED THROUGH THE PARENT, never by entering the directory itself: this
    # script runs UNPRIVILEGED and elevates per step, and the leaf it is asked
    # about is routinely root-owned 0700 ($SYS_DATA_DIR). `cd` into that is
    # EACCES for the operator, while stat'ing it from outside is not — an
    # earlier form entered the leaf and refused every non-root install with a
    # message about `stat` dialects. A symlinked leaf is still followed, since
    # that is the substitution this resolution exists to catch.
    _ds_p="$(cd "$(dirname "$_ds_d")" 2>/dev/null && pwd -P)" || return 2
    [ -n "$_ds_p" ] || return 2
    case "$_ds_d" in
    /) ;;
    *) _ds_d="${_ds_p%/}/$(basename "$_ds_d")" ;;
    esac
    # A SYMLINKED LEAF MUST SATISFY BOTH CHAINS. Resolving to the target and
    # walking only from there ignores the directory that HOLDS the link: with a
    # group-writable /usr/local and /usr/local/bin -> a root-owned tree, the
    # target walks clean while the owner of /usr/local can repoint `bin` at any
    # moment — after which root's own links address someone else's directory.
    # The holder's chain is checked first, then the resolved target's below.
    if [ -L "$_ds_d" ]; then
        dir_chain_is_root_secure "$_ds_p" || return $?
        _ds_d="$(cd "$_ds_d" 2>/dev/null && pwd -P)" || return 2
        [ -n "$_ds_d" ] || return 2
    fi
    dir_chain_is_root_secure "$_ds_d"
}

# dir_chain_is_root_secure DIR — the ownership walk itself, from DIR up to /:
# every level root-owned and writable by nobody else. Split out of
# dir_is_root_secure so a symlinked leaf can be judged by the chain that HOLDS
# the link as well as the one that holds its target. Takes an already-resolved
# path; nothing else calls it.
dir_chain_is_root_secure() {
    _dc_d="$1"
    while :; do
        [ -d "$_dc_d" ] || return 1
        _dc_v="$(stat_uid "$_dc_d")" || return 2
        [ "$_dc_v" = 0 ] || return 1
        _dc_v="$(stat_mode "$_dc_d")" || return 2
        if mode_allows_nonroot_write "$_dc_v"; then return 1; fi
        _dc_parent="$(dirname "$_dc_d")"
        [ "$_dc_parent" != "$_dc_d" ] || break
        _dc_d="$_dc_parent"
    done
    return 0
}
# === ROOT-SECURE CONTRACT END ===

# ---------------------------------------------------------------------------
# root_bin_source <name> — where this run's copy of a root-execed binary comes
# from: the unzipped bundle when there is one (fresh + update modes place
# binaries), otherwise a copy already on disk — either the DEFAULT $BIN_DIR
# established by a previous run, or, for a host converging off the pre-collapse
# layout, the historical per-user default ($HOME/.local/bin, install.sh's own
# default before this DEFAULT moved to a root-owned $BIN_DIR).
#
# The second source is what converges a host installed under 0.2.0 whose $BIN_DIR
# already IS today's default: `@DISPATCHER@ gateway service install` re-runs the kept
# installer with no bundle beside it, but the binaries are already in $BIN_DIR,
# and re-verifying them in place is exactly the repair. The third source is what
# converges an OLDER host: one installed before this DEFAULT moved has its
# binaries sitting at the historical $HOME/.local/bin regardless of what $BIN_DIR
# resolves to on this run, and without this fallback such a host's `service
# install` would find nothing to place at the new default at all — the ladder
# this script climbs cannot climb past a rung it cannot see.
#
# That third source is also the one sweep_stale_user_bins later deletes, and
# the order below is what makes both correct: $BIN_DIR is consulted FIRST, so
# by the time a sweep has run there is nothing left for the fallback to answer
# and nothing that needs it to.
# ---------------------------------------------------------------------------
root_bin_source() {
    for _rbs in "./$1" "$BIN_DIR/$1" "$HOME/.local/bin/$1"; do
        if [ -f "$_rbs" ]; then echo "$_rbs"; return 0; fi
    done
    echo ""
}

# ---------------------------------------------------------------------------
# ensure_root_exec_surface — place every root-execed artifact in $BIN_DIR,
# root-owned, and PROVE it before any unit is allowed to name it. Non-zero
# means no unit may be written this run.
#
# Called from render_units rather than from each mode, so there is exactly one
# place where "the units are about to name these paths" and "these paths are
# safe" are decided together. Writing a unit and verifying its target in two
# different functions is how the two drift apart.
#
# On the ordinary path (fresh install, update mode) $BIN_DIR already holds every
# binary by the time this runs — place_all_bins / the update-mode placement
# already put them there, elevated. This function's OWN placement loop exists
# for BURROWEE_UNITS_ONLY (`service install`, run with no bundle) and for a host
# converging off the historical per-user default via root_bin_source's third
# fallback — the cases where nothing upstream has placed anything yet.
# ---------------------------------------------------------------------------
ensure_root_exec_surface() {
    # The whole tree, not just $BIN_DIR — a units-only run may be the first
    # thing to touch a host since its 0.2 install, and the units it is about
    # to write name the config and data roots too. Every level is created with
    # its owner and mode STATED and the result asserted before a unit may name
    # it; see ensure_system_tree.
    ensure_system_tree || return 1

    for _reb in $ROOT_BINS; do
        if [ -n "$ROOT_BIN_PLACE_EXCLUDE" ] && [ "$_reb" = "$ROOT_BIN_PLACE_EXCLUDE" ]; then
            # The RUNNING updater is never replaced from the bundle — but on the
            # 0.2→0.3 crossing the new exec root has no copy of it at all, and
            # verify_root_exec_surface would refuse every unit. A copy of the
            # running binary from the 0.2 exec root is not a replacement of it.
            if [ ! -f "$BIN_DIR/$_reb" ]; then
                # THE BUNDLE FIRST. Excluding this name from placement means
                # "do not replace the RUNNING updater", and the running one is
                # at $LEGACY_BIN_DIR — so putting the bundle's own verified copy
                # at the new path replaces nothing. It is also the only source
                # here that was signature-checked.
                #
                # $LEGACY_BIN_DIR is the fallback and only when root-secure: it
                # is the directory this layout stopped trusting, console-user
                # owned on the Homebrew Intel Mac the 0.3 tree exists for, and
                # copying an unverified file from there into the root-secure
                # exec root launders it — verify_root_exec_surface inspects the
                # destination, and a root unit then execs it.
                _reb_x="$(root_bin_source "$_reb")"
                case "$_reb_x" in
                "$LEGACY_BIN_DIR/"*) path_is_root_secure "$_reb_x" || _reb_x="" ;;
                "") ;;
                esac
                if [ -z "$_reb_x" ] && [ -f "$LEGACY_BIN_DIR/$_reb" ] \
                    && path_is_root_secure "$LEGACY_BIN_DIR/$_reb"; then
                    _reb_x="$LEGACY_BIN_DIR/$_reb"
                fi
                if [ -z "$_reb_x" ] && [ -e "$LEGACY_BIN_DIR/$_reb" ]; then
                    # A candidate EXISTS and was refused. Say that, rather than
                    # letting verify_root_exec_surface report the destination as
                    # merely absent — an operator told "missing" would go looking
                    # for a placement bug instead of at the file that was skipped.
                    echo "error: $LEGACY_BIN_DIR/$_reb is not root-secure, so it was not copied into $BIN_DIR." >&2
                    echo "error: Re-run the full installer for this component, which carries a verified $_reb," >&2
                    echo "error: rather than adopting whatever sits in the 0.2 exec root." >&2
                    return 1
                fi
                # Nothing anywhere: leave it to verify_root_exec_surface, whose
                # refusal names the destination path and the converging verb.
                if [ -n "$_reb_x" ]; then
                    run_root /usr/bin/install -m 0755 "$_reb_x" "$BIN_DIR/$_reb" || return 1
                    echo "placed $BIN_DIR/$_reb from $_reb_x (the running updater is not replaced)"
                fi
            fi
            continue
        fi
        _reb_src="$(root_bin_source "$_reb")"
        if [ -z "$_reb_src" ]; then
            echo "error: no copy of $_reb to place in $BIN_DIR — refusing to write a unit naming it." >&2
            return 1
        fi
        # Identical content is a no-op, so a steady-state refresh needs no sudo
        # at all — and it is also what keeps a units-only run from asking
        # `install` to copy a file onto itself when root_bin_source's fallback
        # resolves to the very path being written.
        if [ -f "$BIN_DIR/$_reb" ] && cmp -s "$_reb_src" "$BIN_DIR/$_reb"; then continue; fi
        run_root /usr/bin/install -m 0755 "$_reb_src" "$BIN_DIR/$_reb" || return 1
        if [ "$(uname -s)" = "Darwin" ]; then
            run_root xattr -d com.apple.quarantine "$BIN_DIR/$_reb" 2>/dev/null || true
        fi
    done

    # This script and its migrations, so the root updater's offline reinstall has
    # a root-owned installer to exec. The per-user copy at $GW_HOME stays too
    # (keep_installer_copy) — a host with no system install has nothing else to
    # re-run — but root never runs that one.
    if [ ! -f "$BIN_DIR/install.sh" ] || ! cmp -s "$0" "$BIN_DIR/install.sh"; then
        run_root /usr/bin/install -m 0755 "$0" "$BIN_DIR/install.sh" || return 1
    fi
    # guard.sh, for exactly the same reason and by exactly the same rule: the
    # supervisor execs it AS ROOT (guard_arm), so it must sit on a path no
    # unprivileged user can rewrite. It is placed here so that every mode
    # converges it, and re-placed and PROVEN in guard_arm itself, which is the
    # caller that actually hands the path to launchd/systemd.
    #
    # THE `[ -f ]` GUARD IS NOT A TOLERANCE FOR AN UNGUARDED INSTALL. It used
    # to be, and the reason recorded here — "a host converging off a bundle
    # that predates the guard has nothing to place, and must not have `service
    # install` refused over an artefact that run never arms" — stopped being
    # true when units-only started arming. Both install paths now refuse
    # without a guard, in guard_arm, out loud. What this guard still buys is
    # that the refusal happens THERE, with guard_arm's message naming what is
    # missing and why root would have to exec it, rather than here as an
    # `install` of a file that does not exist. See guard_arm's own root-secure
    # refusal.
    _reb_guard="$(dirname "$0")/guard.sh"
    if [ -f "$_reb_guard" ] && { [ ! -f "$BIN_DIR/guard.sh" ] || ! cmp -s "$_reb_guard" "$BIN_DIR/guard.sh"; }; then
        run_root /usr/bin/install -m 0755 "$_reb_guard" "$BIN_DIR/guard.sh" || return 1
    fi
    _reb_migrations="$(dirname "$0")/migrations"

    if [ -d "$_reb_migrations" ] && [ "$_reb_migrations" != "$BIN_DIR/migrations" ]; then
        run_root mkdir -p "$BIN_DIR/migrations" || return 1
        for _reb_m in "$_reb_migrations"/*.sh; do
            [ -f "$_reb_m" ] || continue
            run_root /usr/bin/install -m 0755 "$_reb_m" "$BIN_DIR/migrations/" || return 1
        done
    fi

    verify_root_exec_surface
}

# ---------------------------------------------------------------------------
# verify_root_exec_surface — refuse when anything a unit is about to name, or
# that the root updater will exec, is not root-owned all the way to /.
#
# This is the check that makes the placement above meaningful rather than
# decorative — the SURVIVING invariant of the pre-collapse libexec design, now
# aimed at the bin/ of the machine-owned tree (see the header comment for how
# it got there). /usr/local is root-owned on a modern macOS and on every
# Linux, but it is not GUARANTEED to be, and a host where a package manager
# chowned it would otherwise get a root-scheme unit pointing into a path its
# owner can rewrite. That refusal is UNCHANGED: /usr/local is the ancestor
# every layout so far has walked through. What 0.3 removes is the case where
# /usr/local is fine and its CHILDREN are not — Homebrew's bin/etc/var — by
# never placing anything in them.
# ---------------------------------------------------------------------------
verify_root_exec_surface() {
    if ! have_real_root; then
        echo "note: this run never reached uid 0, so the ownership of $BIN_DIR" >&2
        echo "note: cannot be asserted — skipping the root-secure check." >&2
        return 0
    fi
    for _vre in $ROOT_BINS install.sh; do
        _vre_rc=0
        path_is_root_secure "$BIN_DIR/$_vre" || _vre_rc=$?
        if [ "$_vre_rc" = 0 ]; then continue; fi
        if [ "$_vre_rc" = 2 ]; then
            # Undecidable, not insecure. Naming permissions here would be a lie,
            # and an expensive one — it is a day spent re-checking a tree that
            # was right the first time.
            echo "error: could not read the owner and mode of $BIN_DIR/$_vre — this host's" >&2
            echo "error: 'stat' answered neither the GNU form (stat -c '%u') nor the BSD form" >&2
            echo "error: (stat -f '%u') with a plain number." >&2
            echo "error: refusing to install a service that runs as root out of a path whose" >&2
            echo "error: ownership could not be established." >&2
            echo "hint: the permissions of $BIN_DIR are NOT implicated — reading them is." >&2
            echo "hint: check which stat is on PATH ('command -v stat') and that it is the" >&2
            echo "hint: system one; then re-run '@DISPATCHER@ gateway service install'." >&2
        elif [ "$_vre_rc" = 3 ]; then
            # Absent, not insecure — a different fact, most often the update
            # track excluding this exact name (ROOT_BIN_PLACE_EXCLUDE) on a
            # host that has never had anything placed at $BIN_DIR/$_vre at
            # all, e.g. converging off the pre-collapse layout. "Check its
            # ownership" would send an operator to inspect a path that was
            # never created.
            echo "error: $BIN_DIR/$_vre does not exist — refusing to install a service that" >&2
            echo "error: would run as root out of a path with nothing there." >&2
            echo "hint: this host has never had a binary placed at that path. Run" >&2
            echo "hint: '@DISPATCHER@ gateway service install' to place it and converge the host;" >&2
            echo "hint: an update alone does not create it." >&2
        else
            echo "error: $BIN_DIR/$_vre is not root-owned and unwritable all the way to /." >&2
            echo "error: refusing to install a service that runs as root out of a path a" >&2
            echo "error: non-root user could replace." >&2
            echo "hint: check the ownership and modes of $BIN_DIR and every directory above it;" >&2
            echo "hint: each must be owned by root and not group- or world-writable." >&2
        fi
        return 1
    done

    # guard.sh, checked SEPARATELY and only when it is there.
    #
    # It belongs on this surface — the supervisor execs it as root — but it
    # cannot join the loop above, whose absent case (rc 3) is a refusal. A host
    # converging off a bundle that predates the guard reaches
    # `@DISPATCHER@ gateway service install` with an installer copy and no guard.sh
    # beside it, and refusing there would brick the one verb this script sends
    # operators to, over an artefact that mode never arms. So: present and
    # insecure is a refusal, present and secure is fine, absent is left to
    # guard_arm — the only caller that actually hands the path to root, and the
    # one that refuses outright rather than arming an unverifiable guard.
    #
    # rc 1 and rc 2 kept apart here too — see the loop above. This check was
    # added later than that loop and collapsed them, so a host that could not
    # be READ was told its guard copy was insecure.
    if [ -f "$BIN_DIR/guard.sh" ]; then
        _vre_g_rc=0
        path_is_root_secure "$BIN_DIR/guard.sh" || _vre_g_rc=$?
        if [ "$_vre_g_rc" = 2 ]; then
            echo "error: could not read the owner and mode of $BIN_DIR/guard.sh — this host's" >&2
            echo "error: 'stat' answered neither the GNU form (stat -c '%u') nor the BSD form" >&2
            echo "error: (stat -f '%u') with a plain number." >&2
            echo "error: the install guard is execed AS ROOT by launchd/systemd, so refusing to" >&2
            echo "error: keep a copy whose ownership could not be established." >&2
            echo "hint: the permissions of $BIN_DIR are NOT implicated — reading them is." >&2
            echo "hint: check which stat is on PATH ('command -v stat') and that it is the" >&2
            echo "hint: system one; then re-run '@DISPATCHER@ gateway service install'." >&2
            return 1
        elif [ "$_vre_g_rc" != 0 ]; then
            echo "error: $BIN_DIR/guard.sh is not root-owned and unwritable all the way to /." >&2
            echo "error: the install guard is execed AS ROOT by launchd/systemd, so refusing to" >&2
            echo "error: keep a copy at a path a non-root user could replace." >&2
            echo "hint: check the ownership and modes of $BIN_DIR and every directory above it;" >&2
            echo "hint: each must be owned by root and not group- or world-writable." >&2
            return 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# Single system slot: unit ownership + cross-user override consent.
# ---------------------------------------------------------------------------
core_unit_path() {
    case "$(uname -s)" in
    Darwin) echo "$LAUNCHD_DIR/com.burrowee.@UNIT_DOT@gateway.plist" ;;
    *)      echo "$SYSTEMD_DIR/burrowee-@UNIT_DASH@gateway.service" ;;
    esac
}

# unit_owner <file> — the run-as user recorded in an existing unit file
# (plist UserName / systemd User=). Empty when absent or unowned. Mirrors the
# Go side's UnitOwner so both unit-writers agree on slot ownership.
#
# Every unit this installer writes is now root-scheme and carries NO such
# field, so an empty answer means "root-owned, current scheme" — a FREE slot,
# not an unknown one. Only a legacy per-user unit names an owner, which is what
# makes the consent prompt below fire on exactly the case that still needs it:
# taking over the pre-split service of a different user.
unit_owner() {
    [ -f "$1" ] || { echo ""; return 0; }
    case "$1" in
    *.plist) sed -n 's|.*<key>UserName</key><string>\([^<]*\)</string>.*|\1|p' "$1" | head -n 1 ;;
    *)       sed -n 's|^User=\(.*\)$|\1|p' "$1" | head -n 1 ;;
    esac
}

# check_service_override — when the existing system unit belongs to a
# DIFFERENT user, require consent before replacing it: the force env, or a
# /dev/tty prompt defaulting to abort. Non-interactive without the env aborts.
check_service_override() {
    _owner="$(unit_owner "$(core_unit_path)")"
    if [ -z "$_owner" ] || [ "$_owner" = "$SERVICE_USER" ]; then return 0; fi
    if [ -n "${BURROWEE_FORCE_SERVICE_OVERRIDE:-}" ]; then
        echo "overriding gateway service previously installed for user '$_owner' (BURROWEE_FORCE_SERVICE_OVERRIDE)"
        return 0
    fi
    if has_tty; then
        printf "gateway service is currently installed for user '%s'. Override it for '%s'? [y/N] " "$_owner" "$SERVICE_USER" >/dev/tty
        _answer=''
        IFS= read -r _answer </dev/tty || _answer=''
        case "$_answer" in
        y|Y|yes|YES) return 0 ;;
        esac
    fi
    echo "error: the gateway system service belongs to user '$_owner' — aborting." >&2
    echo "hint: re-run with BURROWEE_FORCE_SERVICE_OVERRIDE=1 (or '@DISPATCHER@ gateway service install --force-service-override') to take it over." >&2
    exit 1
}

# ---------------------------------------------------------------------------
# remove_legacy_user_units — tear down the per-user units this installer wrote
# before the system-level model (launchd gui agents / systemd --user).
# Migration is best-effort: every step tolerates "was never installed".
# ---------------------------------------------------------------------------
remove_legacy_user_units() {
    case "$(uname -s)" in
    Darwin)
        for _label in com.burrowee.gateway com.burrowee.gateway.updater org.burrowee.gateway; do
            launchctl bootout "gui/$(id -u)/$_label" 2>/dev/null || true
            rm -f "$HOME/Library/LaunchAgents/$_label.plist"
        done
        ;;
    Linux)
        systemctl --user disable --now burrowee-gateway.service 2>/dev/null || true
        systemctl --user disable --now burrowee-gateway-updater.service 2>/dev/null || true
        rm -f "$HOME/.config/systemd/user/burrowee-gateway.service" \
              "$HOME/.config/systemd/user/burrowee-gateway-updater.service"
        systemctl --user daemon-reload 2>/dev/null || true
        ;;
    esac
}

# ---------------------------------------------------------------------------
# THE OTHER HALF OF THAT MIGRATION: the stale per-user BINARIES.
#
# remove_legacy_user_units above tears down what the pre-system-level model
# left running. Nothing tore down what it left on disk. Before 0.2.0 this
# installer's destination was $HOME/.local/bin — and the outer bootstrap set
# PREFIX on every `curl … | sh`, so that was not one shape among several, it
# was the shape every host took. 0.2.0 collapsed the destination to a
# root-owned /usr/local/bin and left the old copies exactly where they were.
#
# They do not sit there harmlessly. $HOME/.local/bin PRECEDES /usr/local/bin on
# a normal PATH, so every unqualified `@DISPATCHER@` or `burrowee-gateway-cli` an
# operator types keeps resolving to the OLD binary while the units and every
# absolute-path consumer use the new one — the same split-brain the header's
# outage describes, read from the other end. Observed on a production node the
# day 0.2.1 shipped: `which @DISPATCHER@` → /home/ubuntu/.local/bin/burrowee.
#
# THE ORDERING IS A SAFETY PROPERTY, not a tidiness preference. A host arriving
# here may still be running a unit whose ExecStart names the per-user path; on
# macOS the KeepAlive.PathState this installer writes keys off the binary's
# existence, so unlinking it does not merely stale a future restart, it stops
# the running daemon. So this runs only AFTER the binaries are in $BIN_DIR and
# the units that name them have been rendered AND loaded — and even then it
# refuses when a unit file on this host still names the old directory.
# ---------------------------------------------------------------------------

# WHERE THE SWEEP ITSELF LIVES: migrations/lib_stale_user_bins.sh, inside this
# same bundle, sourced below and sourced by the gateway's 0.2.0 rung
# (migrations/v0_2_stale_user_bins.sh) out of the same directory.
#
# IT USED TO BE OPEN-CODED HERE, and that is exactly why the sweep never ran on
# the host that needed it most. install.sh runs only when somebody runs the
# installer, and THE UPDATER NEVER DOES — it swaps binaries and restarts the
# daemon. So a host updated in place kept its stale per-user copies forever
# (admin-kr, 2026-08-17: daemon at v0.2.0.2026.08.17, ~/.local/bin/burrowee-gateway
# still on the Aug 8 build, and a drift row whose recommended `restart` provably
# could not clear it). Making it a ladder rung is what reaches those hosts.
#
# THE CALL STAYS HERE TOO, and that is deliberate rather than redundant: a
# FRESH install must not depend on the ladder being coherent, the ladder is a
# no-op on a fresh host by construction, and the sweep is idempotent — running
# it twice on one host costs a stat per name.
#
# ONE FILE, TWO CALLERS, no second implementation. Every guard in that library
# fails silently in the safe-looking direction (a sweep pointed at the wrong
# home finds nothing and reports success; a "provably ours" check that admits
# too much deletes an operator's own file and reports success too), so a copy
# that drifted would look exactly like the original right up to the deletion it
# got wrong.

# stale_sweep_lib — the library shipped beside this installer, or empty when
# this bundle carries no migrations/ at all (a $GW_HOME self-copy from an
# install that predates the directory). Same shape and same tolerance as
# migration_runner: a bundle with no migrations/ is an OLD bundle, not a broken
# one, and it stays silent — while a bundle that HAS migrations/ and is missing
# this file is a mis-assembled release, which this project has shipped once and
# must never ship quietly again.
STALE_SWEEP_LOADED=0
stale_sweep_lib() {
    _ssl_dir="$(dirname "$0")/migrations"
    [ -d "$_ssl_dir" ] || return 0
    if [ -f "$_ssl_dir/lib_stale_user_bins.sh" ]; then
        echo "$_ssl_dir/lib_stale_user_bins.sh"
        return 0
    fi
    echo "note: $_ssl_dir carries no lib_stale_user_bins.sh — THIS RELEASE IS INCOMPLETE." >&2
    echo "note: the pre-0.2.0 per-user copies of these binaries are NOT being swept, and" >&2
    echo "note: they precede $BIN_DIR on a normal PATH. Remove them by hand, or re-run a" >&2
    echo "note: complete release." >&2
    return 0
}

# sweep_stale_user_bins — load the library and run its sweep. Named differently
# from the library's own remove_stale_user_bins on purpose: sourcing a file from
# inside a function that shared its name would leave two definitions of one name
# in one shell, and which one a later call reached would depend on whether the
# source had happened yet.
#
# Sourcing happens HERE rather than at the top of the file so a bundle without
# the library still installs: the sweep is a cleanup, not a precondition.
sweep_stale_user_bins() {
    _ssub_lib="$(stale_sweep_lib)"
    [ -n "$_ssub_lib" ] || return 0
    if [ "$STALE_SWEEP_LOADED" != 1 ]; then
        # shellcheck source=/dev/null
        . "$_ssub_lib"
        STALE_SWEEP_LOADED=1
        # THE TWO LISTS MUST AGREE. $BINS is what this installer PLACES; the
        # library's $STALE_USER_BINS is what the sweep removes, and it is the
        # one the ladder rung uses too. A name added to one and not the other is
        # a binary that is installed and never swept — a shadowing copy left on
        # PATH, which is this whole defect — or one swept and never installed.
        # Neither is visible without saying so out loud, because the sweep's
        # normal output on a converged host is nothing at all.
@BETA_ONLY_BEGIN@
        # NOT under the beta root, where the comparison is meaningless and the
        # note is a lie: the sweep exists to remove PRE-0.2.0 per-user copies,
        # every one of which belongs to the stable install, and a beta root
        # never runs it. The lists differ here by construction — this installer
        # places the beta dispatcher, and component.conf names the stable one —
        # so the check would fire on every beta install and say nothing true.
@BETA_ONLY_END@
@STABLE_ONLY_BEGIN@
        if [ "$BINS" != "$STALE_USER_BINS" ]; then
            echo "note: this installer places [$BINS]" >&2
            echo "note: but $_ssub_lib sweeps [$STALE_USER_BINS]." >&2
            echo "note: the two lists disagree, so some name is installed and never swept" >&2
            echo "note: (it keeps shadowing $BIN_DIR on PATH) or swept and never installed." >&2
        fi
@STABLE_ONLY_END@
    fi
    remove_stale_user_bins
}

# sweep_stale_exec_root — the 0.2 exec root's real copies (/usr/local/bin), left
# behind when 0.3 moved the binaries to $BIN_DIR. Same library, same guards.
# Runs from the guard after the verified restart, never before the units have
# moved: while a 0.2 unit still names /usr/local/bin/burrowee-gateway-updater
# the library correctly refuses to unlink it, and the gateway repo's own rung
# runs before render_units on every entry point — so this call is what clears
# the copies on a real host.
sweep_stale_exec_root() {
    _sser_lib="$(stale_sweep_lib)"
    [ -n "$_sser_lib" ] || return 0
    if [ "$STALE_SWEEP_LOADED" != 1 ]; then
        # shellcheck source=/dev/null
        . "$_sser_lib"
        STALE_SWEEP_LOADED=1
    fi
    # The exec-root half lives OUTSIDE the byte-pinned SHARED SWEEP CONTRACT
    # region, and the gateway kit ships the gateway repo's copy of the library:
    # a kit whose library predates it must say so, not die with "not found".
    if ! command -v remove_stale_exec_root_bins >/dev/null 2>&1; then
        echo "note: $_sser_lib has no remove_stale_exec_root_bins — THIS RELEASE IS INCOMPLETE:" >&2
        echo "note: the 0.2 copies in $LEGACY_BIN_DIR were not swept. Re-run a complete release." >&2
        return 0
    fi
    # NO KEEP-LIST. It used to hold every operator-typed name this host had no
    # link at, because with nothing linked there the real 0.2 file was the only
    # copy anything reached by the absolute path — the shared `@DISPATCHER@`
    # dispatcher above all. Nothing resolves by that path any more: no install
    # links there, and $BIN_DIR is what every unit, every root exec and the
    # printed PATH advice name. So the names that used to be deferred to a
    # later run are swept on the FIRST 0.3 run. That is the intended
    # behaviour, not an accident of the refactor.
    remove_stale_exec_root_bins
}

# ---------------------------------------------------------------------------
# print_path_advice — the "Next steps" block this install ends with, rendered
# for the INVOKING operator's login shell by the same shared library the sweeps
# come from (render_path_advice, inside the byte-pinned SHARED SWEEP CONTRACT
# region, so the gateway's copy of that library carries the identical function).
#
# IT IS WHAT REPLACED THE /usr/local/bin SYMLINKS. The exec root is $BIN_DIR,
# which is on nobody's PATH; the operator-typed names used to be linked back
# into /usr/local/bin to compensate, and on a clean modern Mac that directory
# does not exist — so nothing was linked and the install ended with no command
# the operator could type.
#
# NEVER FATAL, AND NEVER SILENT. This runs as the last thing on the success
# path, past every write; dying under `set -eu` with "not found" would report a
# complete install as a failure. A kit whose library predates the renderer still
# owes the operator the one line that makes these commands reachable — that is
# the entire point of this change — so the fallback prints it by hand rather
# than saying nothing.
# ---------------------------------------------------------------------------
print_path_advice() {
    if ! command -v render_path_advice >/dev/null 2>&1; then
        _ppa_lib="$(stale_sweep_lib)"
        if [ -n "$_ppa_lib" ] && [ "$STALE_SWEEP_LOADED" != 1 ]; then
            # shellcheck source=/dev/null
            . "$_ppa_lib"
            STALE_SWEEP_LOADED=1
        fi
    fi
    if command -v render_path_advice >/dev/null 2>&1; then
        render_path_advice "$BIN_DIR"
        return 0
    fi
    echo "note: the loaded sweep library has no render_path_advice — this kit predates the" >&2
    echo "note: shell-aware PATH advice, so here is the one line it would have rendered." >&2
    echo ""
    echo "==> Next steps"
    echo "@DISPATCHER@'s commands are in $BIN_DIR, which is not on your PATH."
    echo ""
    echo "  Add it to this shell now:"
    echo "    export PATH=\"$BIN_DIR:\$PATH\""
    echo ""
    echo "  Then:  @DISPATCHER@ help"
    return 0
}

# ---------------------------------------------------------------------------
# place_unit <rendered-temp-file> <dst> — install a rendered unit at its
# system path as root, only when content differs (a no-op refresh never needs
# sudo). Must stay content-identical with the Go side's unit writers.
#
# IT ALSO RECORDS THAT THE FILE CHANGED, into $TXN_DIR/units-changed, one
# basename per line. That marker is the only thing that tells the guard a
# `kickstart -k` is not enough this run: kickstart restarts the job launchd
# holds IN MEMORY and bootstrap no-ops on an already-loaded label, so with the
# installer's bootout gone nothing re-reads a rewritten plist until the next
# reboot — a changed ExecStart, KeepAlive or StandardOutPath silently not
# taking effect. The guard is the safe place to bootout+bootstrap for it
# (it is detached; see guard.sh's restart_service), and this is how it learns
# it needs to. Written from the WRITE branch only: an unchanged unit records
# nothing, which is exactly the signal.
#
# Best-effort and never fatal. The transaction directory is root-owned 0700, so
# the append goes through run_root like every other write to it; a host where
# that fails loses the reload optimisation, not the install. `tee -a` rather
# than a redirect because the redirect would be opened by THIS shell, which is
# not the one run_root elevates.
# ---------------------------------------------------------------------------
place_unit() {
    if [ -f "$2" ] && cmp -s "$1" "$2"; then
        rm -f "$1"
        echo "service unit: $2 (unchanged)"
        return 0
    fi
    [ -d "$(dirname "$2")" ] || run_root mkdir -p "$(dirname "$2")" || { rm -f "$1"; return 1; }
    run_root /usr/bin/install -m 0644 "$1" "$2" || { rm -f "$1"; return 1; }
    rm -f "$1"
    if [ -n "$TXN_DIR" ]; then
        _pu_base="${2##*/}"
        printf '%s\n' "$_pu_base" | run_root tee -a "$TXN_DIR/units-changed" >/dev/null 2>&1 || true
    fi
    echo "service unit: $2"
}

# ---------------------------------------------------------------------------
# THE MACHINE-OWNED TREE: created level by level with the mode STATED, then
# asserted with the same predicate the daemon applies.
#
# Everything created inside the tree gets its ownership and mode stated
# explicitly. Neither may arrive by inheritance, because all three sources of
# inheritance are wrong:
#
#   * THE UMASK. `mkdir -p` under sudo creates root-owned directories at
#     0777 &^ umask. An operator with `umask 002` gets 0775 — group-writable,
#     and dir_is_root_secure refuses it. This is the shell half of the trap
#     EnsureConfigRoot documents for os.MkdirAll (core config_root.go), whose
#     mode argument is umask-masked too.
#   * THE ARCHIVE. `unzip` restores the modes recorded in the payload, so a
#     binary stored group-writable extracts group-writable. Every binary here
#     is placed with `install -m 0755`, never `cp -p` (place_all_bins,
#     ensure_root_exec_surface).
#   * THE SOURCE FILE. `cp` takes the copy's mode from the source. Same answer.
#
# A NON-ROOT PROCESS MUST NEVER BE THE ONE TO CREATE ANY OF IT: on a host
# where /usr/local is writable by the installing user (Intel macOS, where
# Homebrew chowns it) an unprivileged mkdir succeeds and leaves the root
# daemon's gateway.db, its register/console sockets and its identity inside a
# directory that user fully controls. Every mkdir, chown and chmod here goes
# through run_root, and the tree is ensured BEFORE the first write of every
# mode — before decide_bin_place_elevated's unprivileged writability probe ever
# looks at $BIN_DIR.
#
# The whole tree is OURS by construction: @ROOT@ is created by
# root, beside Homebrew's directories rather than inside them, so every level
# is moded unconditionally — there is no "somebody else's parent" to leave
# alone, which is what the 0.2 layout could never say about /usr/local/etc.
# The one directory this never touches is the parent of $SYSTEM_ROOT
# (/usr/local): a missing one is a refusal, not a mkdir.
#
# launchd applies StandardOutPath at exec, so $SYS_LOG_DIR is part of the tree
# rather than something the daemon creates on first start: a missing log
# directory is a daemon that fails to spawn.
# ---------------------------------------------------------------------------

# ensure_dir_stated <dir> <octal-mode> — one level: create it as root when
# absent (plain mkdir — the caller states EVERY level, and a level whose parent
# is missing is a level outside the tree this script owns), then own and mode
# it. chmod is checked; chown is attempted only where elevation genuinely
# yields uid 0 (have_real_root) and is best-effort even there, because the
# assertion that follows (assert_system_tree) is what decides ownership — a
# chown that "succeeded" proves nothing a stat does not, and a run that never
# reached root cannot assert ownership at all. A steady-state re-run costs
# stats and no sudo: nothing is written unless the stat disagrees.
ensure_dir_stated() {
    _eds_d="$1"; _eds_m="$2"
    if [ ! -d "$_eds_d" ]; then
        if [ ! -d "$(dirname "$_eds_d")" ]; then
            echo "error: cannot create $_eds_d — its parent $(dirname "$_eds_d") does not exist," >&2
            echo "error: and this installer creates nothing above $SYSTEM_ROOT." >&2
            return 1
        fi
        if ! run_root mkdir "$_eds_d"; then
            # A child of a 0700 root-owned directory is invisible to the
            # unprivileged stat above, and mkdir on it fails "File exists": ask
            # root once, only on this failure path, so a steady-state re-run
            # still costs no sudo when everything is visible.
            if ! run_root test -d "$_eds_d"; then
                echo "error: could not create $_eds_d (needs root) — refusing to install a service" >&2
                echo "error: whose state would have to be created by an unprivileged user." >&2
                echo "error: nothing has been installed; no binary was placed." >&2
                return 1
            fi
        fi
    fi
    if have_real_root && [ "$(stat_uid "$_eds_d" 2>/dev/null || echo -)" != 0 ]; then
        run_root chown 0:0 "$_eds_d" 2>/dev/null || true
    fi
    if [ "$(stat_mode "$_eds_d" 2>/dev/null || echo -)" != "${_eds_m#0}" ]; then
        if ! run_root chmod "$_eds_m" "$_eds_d"; then
            echo "error: could not chmod $_eds_m $_eds_d (needs root) — refusing to leave a level" >&2
            echo "error: of the machine-owned tree at a mode this installer did not state." >&2
            echo "error: nothing has been installed; no binary was placed." >&2
            return 1
        fi
    fi
}

# ensure_system_tree — the whole tree, top-down, one level at a time, then
# asserted. The three chains meet at $SYSTEM_ROOT in production (bin/, etc/
# and var/ are siblings under @ROOT@); under the test seams each
# leaf may hang off its own sandbox parent, which is why each chain names its
# own parent rather than assuming the first one's.
#
# The mode column, and why it is not one value: the three parents and bin/
# are 0755 traversal-only directories that hold no secret. etc/gateway is
# 0755 because console.token is 0640 root:<admin-group> and a 0700 parent
# would silently revoke that grant — a mode nobody reading the token could
# detect (the Go side says the same, ConfigRootMode). var/gateway and its
# logs/ are 0700: nothing under them is for a non-owner.
ensure_system_tree() {
@BETA_ONLY_BEGIN@
    # The beta root is one level DEEPER than the stable one, and
    # ensure_dir_stated refuses a level whose parent is absent — correctly, so
    # that nothing here ever creates a directory above the tree we own. On a
    # host that has stable installed the parent is already there; on one that
    # does not, this is the level that has to exist first, and it is still ours
    # (/usr/local, its parent, is not, and is never created here).
    ensure_dir_stated "$(dirname "$SYSTEM_ROOT")" 0755 || return 1
@BETA_ONLY_END@
    ensure_dir_stated "$SYSTEM_ROOT" 0755 || return 1
    ensure_dir_stated "$BIN_DIR" 0755 || return 1
    ensure_dir_stated "$(dirname "$SYS_ETC_ROOT")" 0755 || return 1
    ensure_dir_stated "$SYS_ETC_ROOT" 0755 || return 1
    ensure_dir_stated "$SYS_CONFIG_DIR" 0755 || return 1
    ensure_dir_stated "$(dirname "$SYS_VAR_ROOT")" 0755 || return 1
    ensure_dir_stated "$SYS_VAR_ROOT" 0755 || return 1
    ensure_dir_stated "$SYS_DATA_DIR" 0700 || return 1
    ensure_dir_stated "$SYS_LOG_DIR" 0700 || return 1
    assert_system_tree
}
@BETA_ONLY_BEGIN@

# seed_beta_config — write the ONE key that keeps a beta gateway off the stable
# gateway's console port, and only when this root has no config of its own yet.
#
# 16519 is stable's 16518 plus one, and it is written HERE rather than left to
# the binary's default because the default IS 16518: two gateways on one host
# with no config would both bind it, and the second would fail to start with an
# error about a port neither operator chose. Seed-if-absent, never a rewrite —
# an operator who has moved the beta console has moved it on purpose, and this
# script runs again on every update.
#
# The gateway repo ships etc/gateway/config.beta.example carrying the same
# value (feature 04); this is the installer half of that one fact, and the two
# are checked against each other by nothing but review — see tools/RUNBOOK.md.
seed_beta_config() {
    _sbc="$SYS_CONFIG_DIR/config"
    if [ -e "$_sbc" ]; then
        return 0
    fi
    _sbc_tmp="$(mktemp)" || return 0
    printf 'console_port=16519\n' > "$_sbc_tmp"
    if run_root /usr/bin/install -m 0644 "$_sbc_tmp" "$_sbc"; then
        echo "install: seeded $_sbc with console_port=16519 (stable's port plus one)"
    else
        echo "warning: could not seed $_sbc — set console_port=16519 by hand before starting the beta gateway" >&2
    fi
    rm -f "$_sbc_tmp"
    return 0
}
@BETA_ONLY_END@

# assert_system_tree — refuse when any root of the tree is not root-owned and
# unwritable by non-root all the way to /, with the same predicate the daemon
# applies (dir_is_root_secure, the shell half of IsRootSecureDir).
#
# An invariant checked only at first daemon start is one the operator meets
# as a broken service; checked here it is a failed install naming the
# directory that caused it. The FILES on the surface are asserted separately
# and already — verify_root_exec_surface for what a unit names,
# verify_placement for every binary placed — so this is the directory half
# only. Same gate as both of those: ownership can only be asserted where
# elevation genuinely reached uid 0, and the sandboxed harness's pass-through
# `sudo` never does.
#
# rc 1 (insecure), rc 2 (undecidable) and rc 3 (absent) are three refusals
# with three different next steps, exactly as verify_root_exec_surface keeps
# them apart, and for the same reason: "check your permissions" is a day
# wasted on a tree that was right the first time when what actually happened
# is that stat did not answer.
assert_system_tree() {
    if ! have_real_root; then
        echo "note: this run never reached uid 0, so the ownership of $SYSTEM_ROOT" >&2
        echo "note: cannot be asserted — skipping the root-secure check on the tree." >&2
        return 0
    fi
    for _ast in "$SYSTEM_ROOT" "$BIN_DIR" "$SYS_ETC_ROOT" "$SYS_CONFIG_DIR" "$SYS_VAR_ROOT" "$SYS_DATA_DIR"; do
        _ast_rc=0
        dir_is_root_secure "$_ast" || _ast_rc=$?
        if [ "$_ast_rc" = 0 ]; then continue; fi
        if [ "$_ast_rc" = 2 ]; then
            echo "error: could not read the owner and mode of $_ast — this host's 'stat'" >&2
            echo "error: answered neither the GNU form (stat -c '%u') nor the BSD form" >&2
            echo "error: (stat -f '%u') with a plain number." >&2
            echo "error: refusing to install — the gateway's state would sit in a directory" >&2
            echo "error: whose ownership could not be established." >&2
            echo "hint: the permissions of $_ast are NOT implicated — reading them is." >&2
            echo "hint: check which stat is on PATH ('command -v stat') and that it is the" >&2
            echo "hint: system one; then re-run '@DISPATCHER@ gateway service install'." >&2
        elif [ "$_ast_rc" = 3 ]; then
            echo "error: $_ast does not exist — refusing to install a service whose state" >&2
            echo "error: would sit in a directory this run failed to create." >&2
            echo "hint: re-run '@DISPATCHER@ gateway service install' from an interactive terminal" >&2
            echo "hint: so the directory can be created as root." >&2
        else
            echo "error: $_ast is not root-owned and unwritable all the way to /." >&2
            echo "error: refusing to install — the gateway's state would sit in a directory a" >&2
            echo "error: non-root user could rewrite." >&2
            echo "hint: check the ownership and modes of that directory and every directory" >&2
            echo "hint: above it; each must be owned by root and not group- or world-writable." >&2
        fi
        return 1
    done
}

# ---------------------------------------------------------------------------
# THERE IS NO LINK STEP, AND THIS IS WHERE IT USED TO BE (spec §6.1,
# superseded). It symlinked the operator-typed names from /usr/local/bin into
# $BIN_DIR wherever that directory proved root-secure, deferred that to the
# guard on a 0.2 host whose loaded units still named the link path
# (links_deferred_to_guard), and printed a bare PATH line when it declined.
#
# THE ARGUMENT THAT KILLED IT IS THE SAME ONE THAT BUILT IT. Rule 2 said "link
# ONLY into a root-secure directory", because `unlink` is governed by write
# permission on the CONTAINING directory: in a Homebrew-owned /usr/local/bin
# any user can delete root's link and drop their own file at that name, and the
# operator's next `sudo burrowee-gateway-cli` runs it as root. That reasoning
# still holds exactly — what turned out to be false is the sentence after it,
# "on the host this layout was written for it passes". On a clean modern Mac
# /usr/local/bin does not exist at all, so the check answers "absent" and the
# refusal path IS the normal path; on a Mac where brew got there first it
# refuses for the opposite reason. Both are the majority case. A step whose
# safe branch is the rare one is not a fallback, it is a coin flip that leaves
# half the fleet with an installed component and no command to type.
#
# Rules 3 and 4 (replace, never write through; remove on uninstall) had that
# link as their whole subject and go with it, and so does the deferral: with no
# link to make, there is nothing for the guard's post-restart housekeeping to
# be handed. Rule 1 — nothing root execs ever names a link — survives and is
# now trivially true, because no link exists: every unit, the updater's
# ServeBin and the runner's cli path name $BIN_DIR, enforced by the renderers.
#
# WHAT REPLACES IT is print_path_advice, which a successful install ends with:
# the export line for the INVOKING operator's own login shell, the profile file
# that makes it permanent, printed and never applied. See its header, and
# render_path_advice in the shared sweep library.
#
# unlink_operator_bins stays, and is the ONLY thing in this file that still
# touches $LEGACY_BIN_DIR by name — see its own header for why an uninstall
# still has work to do there.
# ---------------------------------------------------------------------------

# --- LINK OWNERSHIP · BYTE-IDENTICAL COPY · do not edit one copy -------------
# This block exists three times in the release repo — in
# _shared/migrations/lib_stale_user_bins.sh (inside the SHARED SWEEP CONTRACT
# region, so it travels to the gateway repo's copy of that library too) and in
# inner/gateway/install.sh and inner/edge/install.sh beside
# unlink_operator_bins. The sweep and the uninstall must not disagree about
# which links are ours, and the uninstall path cannot depend on the library
# being loaded: the gateway sources it lazily, from inside its sweep functions.
# The copies are pinned byte-identical by TestLinkOwnershipCopiesAreIdentical,
# the same way the PREFIX gate's four copies are pinned by
# tools/prefix-gate-drift.test.sh.
#
# link_target_is_ours <link-path> — whether <link-path> is a symlink this
# project placed: one whose target names a file DIRECTLY inside $BIN_DIR.
#
# IT USED TO BE A PREFIX MATCH — `case "$(readlink "$p")" in "$BIN_DIR"/*)` —
# and that accepted a shape no install ever created: a target of
# "$BIN_DIR/../../etc/foo" begins with "$BIN_DIR/" and so read as ours, and a
# foreign link at a burrowee-typed name was removed on that evidence. The blast
# radius was bounded — removing a symlink unlinks the LINK and never its
# target, and the name has to be in the candidate list already — so this was a
# false-positive removal rather than a traversal write. It was still a decision
# made on a string that did not mean what the comparison assumed.
#
# WHAT THE PREFIX FORM DID GET RIGHT, so nobody "fixes" it back the other way:
# a SIBLING directory was never a hole. The pattern carries an explicit "/"
# after $BIN_DIR, so "$BIN_DIR-old/burrowee" did not match it. That case is
# asserted below anyway, because the exact-directory rule is what keeps it
# true rather than the accident of a trailing slash in a glob.
#
# NO PATH ARITHMETIC, AND THAT IS THE POINT. A target carrying a "." or ".."
# component is REFUSED outright rather than folded, and so is one carrying a
# doubled or trailing slash. Folding would be claiming to know where a path
# LANDS, which is a different and racy question from the one being asked —
# normalize_dir's header makes the same argument about the PREFIX gate — and
# every shape refused here is one no install ever wrote: each link was
# `ln -sfn "$BIN_DIR/<name>"`, absolute and clean. So the refusal costs nothing
# real and fails toward KEEP, the direction every guard here fails in.
#
# THE DIRECTORY MUST BE $BIN_DIR EXACTLY, not merely a prefix of the target.
link_target_is_ours() {
    _ltio_t="$(readlink "$1" 2>/dev/null)"
    [ -n "$_ltio_t" ] || return 1
    # Absolute only: every link this project created was an absolute
    # "$BIN_DIR/<name>". A relative target is somebody else's by construction.
    case "$_ltio_t" in
    /*) ;;
    *) return 1 ;;
    esac
    # The trailing slash makes the LAST component testable the same way as
    # every other one; an absolute path's FIRST component can never be "." or
    # "..", so no leading guard is needed.
    case "$_ltio_t/" in
    */./* | */../* | *//*) return 1 ;;
    esac
    _ltio_b="${BIN_DIR:-}"
    [ -n "$_ltio_b" ] || return 1
    # One trailing slash tolerated on $BIN_DIR, which is caller-supplied.
    # Nothing else about it is normalised: every other reader uses it raw, and
    # a second spelling here would be a second answer to "where is the install".
    _ltio_b="${_ltio_b%/}"
    [ "${_ltio_t%/*}" = "$_ltio_b" ] || return 1
    # Something must remain after the directory: "$BIN_DIR" itself names no file.
    [ -n "${_ltio_t##*/}" ] || return 1
    return 0
}
# --- end LINK OWNERSHIP ------------------------------------------------------

# unlink_operator_bins — an uninstall clears a link a PREVIOUS release left in
# the 0.2 exec root, and only when it still points into OUR tree. A regular
# file at one of these names is the operator's; a symlink pointing anywhere
# else is somebody else's.
#
# NOTHING THIS SCRIPT DOES CREATES ONE ANY MORE, and that is not a reason to
# delete this: hosts installed by a 0.3 release that still linked are carrying
# those links right now, and an uninstall that left them behind would leave a
# dangling name in a directory on the operator's PATH. The install path clears
# them the other way, through the stale-exec-root sweep (a symlink into
# $BIN_DIR is ours and is removed); this is the same cleanup on the way out.
unlink_operator_bins() {
    for _uob in $OPERATOR_BINS; do
        _uob_p="$LEGACY_BIN_DIR/$_uob"
        [ -L "$_uob_p" ] || continue
        link_target_is_ours "$_uob_p" || continue
        # A link whose target still exists is still serving someone: the shared
        # `@DISPATCHER@` dispatcher stays in $BIN_DIR while a sibling component is
        # installed, and its link must stay with it. Same rule as the edge's.
        [ -e "$_uob_p" ] && continue
        run_root rm -f "$_uob_p" || echo "note: could not remove the link $_uob_p (needs root) — remove it by hand" >&2
    done
}

# ---------------------------------------------------------------------------
# migration_runner — the path of the runner shipped beside this installer, or
# empty when this bundle carries none (a $GW_HOME self-copy from an install that
# predates migrations/, or a component zip built before the dir existed).
# ---------------------------------------------------------------------------
migration_runner() {
    _r="$(dirname "$0")/migrations/run.sh"
    if [ -f "$_r" ]; then echo "$_r"; else echo ""; fi
}

# ---------------------------------------------------------------------------
# assert_can_migrate <cli-path> — refuse, BEFORE anything on this host has been
# written, when the migration this bundle carries could not complete.
#
# The runner calls `burrowee-gateway-cli migrate` and probes the INSTALLED cli
# for that verb (migrations/run.sh: cli_supports_migrate). The verb arrived
# after 0.1.115, so on a live 0.1.115 host the cli on disk does not have it.
#
# Discovering that from inside the runner is far too late. install.sh exits 1
# and records no version, so the CALLER reports a failed update — but by then
# the binaries have been swapped and render_units has already written the
# root-scheme units to /Library/LaunchDaemons. Nothing removes them. On the next
# reboot launchd bootstraps the root daemon against an empty system config root,
# it mints a fresh relay_ed.key, and the node re-registers as a NEW node,
# orphaning its console pairing, targets and domains. A failed update that
# silently rebuilds the host's identity at the next power cycle is the worst
# outcome available, and it is reached through the "safe" branch.
#
# So the probe moves in FRONT of every write. The invariant it establishes: no
# unit file is written and no binary is swapped unless the migration is known to
# be able to complete. The caller passes the cli the runner will actually probe
# — the staged one in the bundle for the modes that place binaries (they place
# the cli too, see BINS), the installed one for units-only, which places none.
# ---------------------------------------------------------------------------
#
# migrate_cli_path — the cli the runner will actually probe.
#
# THIS MUST SHARE root_bin_source's fallback chain, not just name $BIN_DIR —
# a host still converging off the historical per-user default (root_bin_source's
# third fallback) has no cli at $BIN_DIR yet on its FIRST `service install`,
# and ensure_root_exec_surface is about to find and copy one from there
# moments after this pre-flight runs. A version that checked only $BIN_DIR
# refused every such host with "the cli does not provide 'migrate'" — true
# of the empty path it checked, false of the real one root_bin_source would
# have found — which is exactly the class of host this pre-flight exists to
# let through, not block.
migrate_cli_path() {
    _mcp="$(root_bin_source burrowee-gateway-cli)"
    if [ -n "$_mcp" ]; then echo "$_mcp"; return 0; fi
    echo "$BIN_DIR/burrowee-gateway-cli"
}

#
# The refusal names what the probe actually saw. "Does not provide it" once
# covered every failure, including a staged binary that could not run on the
# host at all (SIGABRT — "Abort trap: 6"), and then sent the operator to
# install a release "that carries the verb" — the very release that had just
# crashed. A signal death is a different defect from a missing verb and gets
# a different hint.
assert_can_migrate() {
    if [ -z "$(migration_runner)" ]; then return 0; fi
    if [ ! -x "$1" ]; then
        _acm_why="$1 is not an executable file"
        _acm_hint=verb
    else
        set +e
        "$1" migrate --help >/dev/null 2>&1
        _acm_rc=$?
        set -e
        if [ "$_acm_rc" = 0 ]; then return 0; fi
        if [ "$_acm_rc" -ge 128 ]; then
            _acm_why="'$1 migrate --help' died with signal $((_acm_rc - 128)) (exit $_acm_rc): the binary does not run on this host"
            _acm_hint=host
        else
            _acm_why="'$1 migrate --help' exited $_acm_rc: the cli does not provide the verb"
            _acm_hint=verb
        fi
    fi
    echo "error: this release's state migration needs 'burrowee-gateway-cli migrate'," >&2
    echo "error: and $_acm_why — refusing before anything is changed." >&2
    echo "hint: nothing has been touched: no binary was replaced and no service unit written." >&2
    if [ "$_acm_hint" = host ]; then
        echo "hint: the staged binary itself failed, not the verb — check that it runs here at all:" >&2
        echo "hint:   $1 --version    (wrong architecture, or an OS this build does not support?)" >&2
    else
        echo "hint: install the current release first (it ships a cli that carries the verb):" >&2
        echo "hint:   curl -fsSL https://release.burrowee.com/gateway/install.sh | sh" >&2
    fi
    exit 1
}

# ---------------------------------------------------------------------------
# prior_install_present — is there ALREADY a gateway on this host for the
# ladder to migrate? The fresh-install pre-flight is owed only to such a host.
#
# assert_can_migrate exists for a host WITH pre-0.2.0 state: an install that
# swapped its binaries and wrote root-scheme units, then found the cli could
# not migrate, leaves that host to re-register as a NEW node at the next
# reboot. A host with no gateway on it has nothing the runner would migrate —
# it evaluates the (absent) tree and declines by itself, never calling the
# verb — so demanding the verb up front refuses the install over a migration
# that could not run. Seen live on a new server: the staged cli aborted on
# that host, the probe read the crash as "does not provide 'migrate'", and the
# fresh install stopped before placing a single binary.
#
# Every way a prior install shows itself is probed on its own — no shared
# gate: the tree the ladder reads, the cli at $BIN_DIR, the cli at the
# historical per-user default, and — running as root on another user's behalf
# — that user's copies of both, because that is the tree the runner will name
# (run.sh's $SUDO_USER rule). An explicit $ADOPT_FROM is a prior install by
# declaration. Only the pre-flight hangs on this answer: the runner is handed
# the host either way and stays the one authority on what it needs.
# ---------------------------------------------------------------------------
#
# home_of_user <name> — the account's home, or non-zero. The lookup the
# runner's lib_paths.sh makes (getent on Linux, dscl on macOS), without its
# legacy-parents sweep: an account this host cannot resolve is not evidence
# of a prior install.
home_of_user() {
    _hou=""
    if command -v getent >/dev/null 2>&1; then
        _hou="$(getent passwd "$1" 2>/dev/null | cut -d: -f6)"
    fi
    if [ -z "$_hou" ] && command -v dscl >/dev/null 2>&1; then
        _hou="$(dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')"
    fi
    [ -n "$_hou" ] || return 1
    echo "$_hou"
}

prior_install_present() {
    if [ -d "$GW_HOME" ]; then return 0; fi
    if [ -e "$BIN_DIR/burrowee-gateway-cli" ]; then return 0; fi
    if [ -e "$HOME/.local/bin/burrowee-gateway-cli" ]; then return 0; fi
    if [ -n "${ADOPT_FROM:-}" ]; then return 0; fi
    if [ "$(id -u)" = 0 ]; then
        case "${SUDO_USER:-}" in
        '' | root) ;;
        *)
            _pip_home="$(home_of_user "$SUDO_USER" || true)"
            if [ -n "$_pip_home" ] && [ -d "$_pip_home/.burrowee/gateway" ]; then return 0; fi
            if [ -n "$_pip_home" ] && [ -e "$_pip_home/.local/bin/burrowee-gateway-cli" ]; then return 0; fi
            ;;
        esac
    fi
    return 1
}

# ---------------------------------------------------------------------------
# migration_sudo [probe] — the elevation command handed to the runner, following
# THIS script's own root policy (run_root): a prompting `sudo` only when there is
# a controlling tty to prompt on, `sudo -n` otherwise. An explicit SUDO from the
# caller wins in either mode, so the updater's own seam still reaches the runner.
#
# The documented install flow is `curl … | sh`, where stdin is the pipe. A bare
# `sudo` there fails with "no tty present and no askpass program" — and it fails
# AFTER the runner has stopped the gateway, with none of run_root's hint text.
#
# `probe` IS THE READ-ONLY CALLER, AND IT NEVER PROMPTS, tty or no tty.
# should_ask_before_migration forks the runner with BOTH streams discarded
# (`>/dev/null 2>&1`), because the only thing it wants from that run is the exit
# code. A prompting `sudo` inside it is therefore a bare `Password:` on the
# operator's terminal with every line that would explain it thrown away — the
# runner's `receipt_state` reads a 0600 root-owned receipt through $SUDO, so it
# is a real read on a real host and not a hypothetical. Worse, it is a prompt
# for a decision the operator has not been shown yet: the probe runs BEFORE the
# consent prompt it exists to decide whether to ask.
#
# The cost of `-n` here is nil in the normal case and small in the worst one.
# The identical read happens seconds later in the real run — with a warm sudo
# timestamp on essentially every host, and with run_root's own prose around it
# when it is not — and a probe that cannot read a receipt answers 12, which
# should_ask_before_migration already treats as "cannot tell, proceed exactly as
# today". Losing a warning is what a blind probe costs. It is a much better
# trade than an unexplained password prompt.
# ---------------------------------------------------------------------------
migration_sudo() {
    if [ -n "${SUDO:-}" ]; then echo "$SUDO"; return 0; fi
    if [ "${1:-}" = probe ]; then echo "sudo -n"; return 0; fi
    if has_tty; then echo "sudo"; else echo "sudo -n"; fi
}

# ---------------------------------------------------------------------------
# record_installed_version <version> — write the migration ladder's version
# anchor at $GW_HOME/.installed-version.
#
# The runner gates each migration on `installed_version < target` and falls back
# to the migration's own --applies probe only when NOTHING is recorded. Leaving
# the anchor unwritten is therefore not a safe default: it routes every host to
# the path the runner's own header calls exceptional, and any future migration
# that cannot recognise its precondition structurally silently never runs.
#
# The version may arrive as the release TAG, which carries a "<component>/"
# prefix (gateway/v0.1.115.2026.08.06.d0d79ec6). The runner reads dot-separated
# fields as numbers, so "gateway/v0" is non-numeric and resolves the whole
# version to 0.0.0 — which would make a freshly-installed 0.2.x host look older
# than every migration ever written. Strip the prefix here, where the shape is
# known; the runner already strips a leading "v".
#
# NOTE for the gateway repo: gateway/update.sh (the console-push path) still has
# no writer for this file, so a host updated only by push keeps whatever anchor
# its last install.sh run left. That half belongs to the gateway repo — see the
# platform review's H8.
# ---------------------------------------------------------------------------
#
# It is written to BOTH roots, and they answer different questions. $GW_HOME's
# copy is the migration ladder's anchor — run.sh reads it and it describes the
# per-user tree the rungs migrate FROM. The $BIN_DIR copy is the updater's: on a
# root-scheme host core's local-update path reads <component home>/.installed-
# version to decide whether an install is already current, and that home is now
# $BIN_DIR. One writer for both keeps them from disagreeing.
#
# The $BIN_DIR copy used to be guarded on $SYS_CONFIG_DIR existing — "has this
# host been converged to the root scheme yet". Since 0.3 every mode that
# records a version has already established the whole machine-owned tree
# (ensure_system_tree, before its first write), so the answer is always yes
# and the guard would be dead: both anchors are written, unconditionally. The
# $BIN_DIR copy moves WITH $BIN_DIR to @ROOT@/bin, and the root
# updater reads it from there (core's local-update path, <exec dir>/
# .installed-version); the uninstall block removes it from the same place.
record_installed_version() {
    _ver="${1##*/}"
    if [ -z "$_ver" ]; then return 0; fi
    mkdir -p "$GW_HOME"
    printf '%s\n' "$_ver" > "$GW_HOME/.installed-version"
    printf '%s\n' "$_ver" | run_root tee "$BIN_DIR/.installed-version" >/dev/null || true
}

# ---------------------------------------------------------------------------
# should_ask_before_migration — whether migrate_from_legacy is about to stop the
# daemon on a run where there is somebody to warn.
#
# THE SECOND SEVER POINT. There are two places an install stops the gateway, and
# only one of them is the restart: the migration ladder stops it to copy state at
# rest (gateway's own migrations/run.sh, stop_gateway), a long way before the
# guard is ever handed the restart. On a host administered THROUGH that gateway
# the migration takes the operator's session with it, and a consent prompt
# reached afterwards is asked of a terminal that is already gone.
#
# BOTH GUARDED PATHS ASK IT — the fresh install and BURROWEE_UNITS_ONLY. The
# units-only one is `gateway service install` and `doctor --fix`, which is the
# shape an operator repairing a host over their own tunnel actually types.
#
# THE RUNNER IS THE ONLY AUTHORITY ON "IS ANYTHING PENDING", and this function
# does not become a second one. It asks — `run.sh --probe-pending` — and the
# runner answers by walking the identical ladder a real run walks: the same
# version gate, the same receipt states, the same per-rung --applies. A copy of
# that decision here could disagree with the run that follows it seconds later,
# and a warning that does not match what happens is worse than no warning.
# Probe codes: 10 pending · 11 nothing pending · 12 could not evaluate.
#
# CANNOT TELL MEANS PROCEED AS TODAY, never refuse and never prompt. Three
# distinct answers land there — a runner that predates the mode, a payload
# assembled before it, and a ladder that refused to evaluate — and on every one
# of them today's install already proceeds without a warning. Refusing would
# break every install driven from a kept installer; prompting on a guess would
# teach operators that the warning means nothing. The host is not at risk either
# way: guard_arm runs BEFORE this, so a session severed unannounced leaves the
# installer dead at phase `replacing` and the guard rolls the host back unaided.
# What "cannot tell" costs is the warning, which is exactly what it costs today.
#
# THE RUNNER IS READ BEFORE IT IS INVOKED, and that grep is not belt-and-braces.
# The first shipped runner (gateway #246) parsed no arguments at all: handed
# --probe-pending it would ignore it and RUN THE LADDER, stopping the daemon at
# the precise moment this function exists to warn about. `keep_installer_copy`
# leaves a runner under $GW_HOME for later `service install` runs, so a runner
# that old is reachable from a real host rather than only from history. A file
# that does not carry the mode is never handed it.
#
# NOBODY TO WARN, NO PROBE. consent_to_sever returns immediately without a tty
# and under BURROWEE_ASSUME_YES, so on a console push, in CI and under
# `curl … | sh` the answer would be discarded — and this is what keeps the new
# call site incapable of blocking a non-interactive install: it never even forks
# the probe there.
# ---------------------------------------------------------------------------
should_ask_before_migration() {
    if [ -n "${BURROWEE_ASSUME_YES:-}" ] || ! has_tty; then return 1; fi
    _probe_runner="$(migration_runner)"
    if [ -z "$_probe_runner" ]; then return 1; fi
    grep -q -- '--probe-pending' "$_probe_runner" 2>/dev/null || return 1
    set +e
    # The SAME environment migrate_from_legacy hands the runner. A probe that
    # resolved a different $GW_HOME, a different config root or a different
    # $BIN_DIR would be answering about a different host than the run it speaks
    # for — see that function's header for what each of these values is.
    # `migration_sudo probe`, not `migration_sudo`: this fork discards both
    # streams, so a prompting sudo inside it is a naked `Password:` with its
    # own explanation thrown away. See migration_sudo's header.
    GW_HOME="$GW_HOME"         PREFIX="$(dirname "$BIN_DIR")"         BURROWEE_SYSTEM_CONFIG_DIR="$SYS_CONFIG_DIR"         BURROWEE_SYSTEM_DATA_DIR="$SYS_DATA_DIR"         SUDO="$(migration_sudo probe)"         sh "$_probe_runner" --probe-pending >/dev/null 2>&1
    _probe_rc=$?
    set -e
    # 10 and nothing else. Every other code — 11, 12, an old runner's 64, or
    # anything a future runner invents — is "do not warn", which is what this
    # host does today.
    [ "$_probe_rc" = 10 ]
}

# ---------------------------------------------------------------------------
# migrate_from_legacy — run the release's migrations/run.sh, which walks every
# migration in its ledger and runs the ones this host has not reached yet.
#
# The runner owns the whole decision: it resolves the installed version, gates
# each migration on `installed_ver < target`, runs them oldest first, and records
# each one that completes. It is a no-op unless one applies, so this may be
# called unconditionally.
#
# Called BEFORE any step that starts the gateway, never after: the runner stops
# the gateway so its state is at rest while it is copied, and leaves the restart
# to us.
#
# It places no units and knows nothing about them. Unit placement is render_units
# + load_units below, on the paths that have them; reaching the units from inside
# a migration would mean re-entering this script via `service install` and
# booting out whichever supervisor is running it.
#
# MIGRATED is set when the runner reports exit 2 — "migrations ran, the gateway is
# stopped" — so a mode with no load_units step can say so rather than leaving the
# operator to discover a stopped service.
#
# Exit 3 is exit 2 plus "and the receipt could not be written". The migration
# ran, so the gateway is stopped exactly as for 2; what differs is that the only
# surviving gate on re-running it is the version anchor. Recording the version
# there would convert a receipt-gated, re-runnable migration into a
# version-gated never-again one, so MIGRATE_UNRECORDED suppresses the write and
# the next install re-runs the migration (every migration is idempotent).
#
# Any other non-zero is FATAL. Carrying on would start the new root units against
# a config root with no identity: the daemon then either refuses to start or mints
# a fresh one, and a new relay_ed.key re-registers this host as a NEW node,
# orphaning its console pairing, targets and domains.
#
# Not found is not an error: BURROWEE_UNITS_ONLY can run from $GW_HOME's
# self-copy, and an install predating the migrations/ dir has none beside it.
# ---------------------------------------------------------------------------
MIGRATED=0
MIGRATE_UNRECORDED=0
migrate_from_legacy() {
    _runner="$(migration_runner)"
    if [ -z "$_runner" ]; then return 0; fi
    # The root-owned copies go in BEFORE the runner, not with the units after it.
    # The runner shells to burrowee-gateway-cli AS ROOT (v0_1_to_v0_2.sh's `elevate
    # "$CLI" migrate`), and on the console-push path nobody is watching — so a
    # migration that could only reach a per-user cli is the same escalation the
    # per-user ExecStart was. Both the runner and this script resolve the cli out
    # of $BIN_DIR, root-owned, which is what this call makes true.
    if ! ensure_root_exec_surface; then
        echo "error: could not establish a root-owned $BIN_DIR — refusing to run a" >&2
        echo "error: state migration that would exec a per-user binary as root." >&2
        echo "hint: nothing has been migrated; fix the cause reported above and re-run." >&2
        exit 1
    fi
    set +e
    # The runner's own PREFIX is derived from $BIN_DIR (its parent), not
    # reconstructed from a stale fallback. $PREFIX is always unset in THIS
    # script by the time this runs (the gate at the top refuses a divergent one
    # and clears an accepted one), and a hardcoded
    # "${PREFIX:-$HOME/.local}"
    # would hand the runner the OLD pre-collapse default regardless of what
    # $BIN_DIR actually resolved to (the real /usr/local, or a test's
    # BURROWEE_BIN_DIR redirect) — the runner would then compute a DIFFERENT
    # BIN_DIR than this script just placed everything into. dirname(BIN_DIR)
    # round-trips through the runner's own "${PREFIX:-...}/bin" exactly.
    GW_HOME="$GW_HOME" \
        PREFIX="$(dirname "$BIN_DIR")" \
        BURROWEE_SYSTEM_CONFIG_DIR="$SYS_CONFIG_DIR" \
        BURROWEE_SYSTEM_DATA_DIR="$SYS_DATA_DIR" \
        SUDO="$(migration_sudo)" \
        sh "$_runner"
    _rc=$?
    set -e
    case "$_rc" in
    0) ;;
    2) MIGRATED=1 ;;
    3) MIGRATED=1; MIGRATE_UNRECORDED=1 ;;
    *)
        echo "error: a state migration failed — stopping before the service is started." >&2
        echo "hint: $GW_HOME is untouched; fix the cause reported above and re-run this installer." >&2
        exit 1
        ;;
    esac
}

# ---------------------------------------------------------------------------
# report_unrecorded_migration — say that a migration completed without its
# receipt, and that the version anchor was withheld on purpose so it runs again.
# Every mode that calls migrate_from_legacy calls this after it.
# ---------------------------------------------------------------------------
report_unrecorded_migration() {
    if [ "$MIGRATE_UNRECORDED" != "1" ]; then return 0; fi
    echo "note: a migration completed but its receipt could not be written." >&2
    echo "note: the installed version is deliberately NOT recorded, so the next install" >&2
    echo "note: re-runs the migration (they are idempotent) rather than gating it off" >&2
    echo "note: on a version number with no receipt behind it." >&2
}

# ---------------------------------------------------------------------------
# keep_installer_copy — keep this installer AND the migrations beside it under
# $GW_HOME, so a later `service install` can re-render units and run any pending
# migration without a fresh download.
#
# Both, in every mode. install.sh resolves the runner relative to its OWN path, so
# a $GW_HOME holding install.sh without migrations/ is an installer that silently
# cannot migrate — and `@DISPATCHER@ gateway service install` is the remedy this
# script points operators at.
# ---------------------------------------------------------------------------
keep_installer_copy() {
    mkdir -p "$GW_HOME"
    cp "$0" "$GW_HOME/install.sh" 2>/dev/null || true
    _src_migrations="$(dirname "$0")/migrations"
    if [ -d "$_src_migrations" ]; then
        mkdir -p "$GW_HOME/migrations"
        if ! cp "$_src_migrations"/*.sh "$GW_HOME/migrations/" 2>/dev/null; then
            echo "note: could not keep a copy of migrations/ at $GW_HOME — a later" >&2
            echo "note: '@DISPATCHER@ gateway service install' will not be able to migrate." >&2
        fi
    fi
    # guard.sh too, off the same resolution guard_arm's SOURCE uses
    # ("$(dirname "$0")/guard.sh"), so a later default-mode re-run of this kept
    # copy has a guard to place onto the root-secure surface.
    #
    # FOR A UNITS-ONLY RE-RUN TOO, and that is a correction of a correction.
    # This note twice said the opposite: first that units-only needed the copy,
    # then that it never reaches guard_arm at all. The second was true of the
    # unguarded units-only mode and is not true now — `service install` and
    # `doctor --fix` arm the same guard the fresh path does, out of
    # "$(dirname "$0")/guard.sh", and $GW_HOME/install.sh is one of the two
    # scripts the cli resolves to run (gatewayInstallScript). A $GW_HOME
    # holding install.sh with no guard.sh beside it is therefore a host on
    # which `service install` REFUSES, the same way the fresh path refuses,
    # rather than one that quietly installs unguarded.
    #
    # This copy stays a SOURCE and never an exec target either way. The copy a
    # guard is actually run from is the ROOT-OWNED one under $BIN_DIR
    # (ensure_root_exec_surface places it, guard_arm re-places and PROVES it);
    # root never runs this file — see ensure_root_exec_surface's note beside
    # the install.sh copy, and guard.sh's own header.

    _src_guard="$(dirname "$0")/guard.sh"
    if [ -f "$_src_guard" ]; then
        if ! cp "$_src_guard" "$GW_HOME/guard.sh" 2>/dev/null; then
            echo "note: could not keep a copy of guard.sh at $GW_HOME — a later" >&2
            echo "note: '@DISPATCHER@ gateway service install' will not be able to arm the guard." >&2
        fi
    fi
}

# ---------------------------------------------------------------------------
# render_units — write both SYSTEM service unit FILES for the host init
# system (as root, via place_unit). Does NOT start, stop, or reload any live
# services. Call load_units after render_units when a live reload is desired
# (fresh install / units-only).
#
# It places the PRIVILEGED BINARIES first and returns non-zero when it could not
# prove them root-owned, because the alternative is worse than no units at all:
# a unit is durable, the supervisor execs what it names as root at every boot,
# and nothing rewrites it until an install runs again. There is no retry that
# undoes a bad one. Every caller already handles a non-zero return — the two
# install paths abort under `set -e`, update mode prints its "run service
# install" note — so the refusal costs a host its units, never its identity.
#
# UNGATED since the per-user prefix flow was removed. It used to no-op whenever
# PREFIX was set — which, because the outer bootstrap always set it, meant a
# `curl … | sh` install silently wrote no units at all. There is now exactly one
# install shape and it always gets its units, or it fails saying why.
# ---------------------------------------------------------------------------
render_units() {
    ensure_root_exec_surface || return 1
    case "$(uname -s)" in
    Darwin)
        # Core unit. KeepAlive.PathState restarts the daemon after ANY exit
        # while the binary exists (a graceful SIGTERM exit is the
        # update-restart mechanism) and waits quietly when the volume holding
        # the binary is not mounted yet. WorkingDirectory=/tmp keeps launchd
        # out of possibly TCC-protected paths.
        _tmp_unit="$(mktemp)"
        cat > "$_tmp_unit" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.burrowee.@UNIT_DOT@gateway</string>
  <key>ProgramArguments</key><array><string>$BIN_DIR/burrowee-gateway</string><string>--no-open</string>@UNIT_ROOT_PLIST_ARGS@</array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>WorkingDirectory</key><string>/tmp</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>PathState</key><dict><key>$BIN_DIR/burrowee-gateway</key><true/></dict></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$SYS_LOG_DIR/gateway.log</string>
  <key>StandardErrorPath</key><string>$SYS_LOG_DIR/gateway.err.log</string>
</dict></plist>
EOF
        place_unit "$_tmp_unit" "$LAUNCHD_DIR/com.burrowee.@UNIT_DOT@gateway.plist"

        # Updater unit. No path flags: the updater agent resolves its own roots,
        # which already default to the system pair under root's euid — the same
        # defaulting the core unit's flags only make explicit.
@BETA_ONLY_BEGIN@
        # UNDER THE BETA ROOT IT PASSES --home, and must: that defaulting knows
        # only the STABLE pair, so a beta updater without it would fetch, place
        # and restart against the other channel's tree (gateway feature 04,
        # updater_agent.RunForHome).
@BETA_ONLY_END@
        _tmp_unit="$(mktemp)"
        cat > "$_tmp_unit" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.burrowee.@UNIT_DOT@gateway.updater</string>
  <key>ProgramArguments</key><array><string>$BIN_DIR/burrowee-gateway-updater</string><string>run</string>@UPDATER_HOME_PLIST_ARGS@</array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>WorkingDirectory</key><string>/tmp</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>PathState</key><dict><key>$BIN_DIR/burrowee-gateway-updater</key><true/></dict></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$SYS_LOG_DIR/updater.log</string>
  <key>StandardErrorPath</key><string>$SYS_LOG_DIR/updater.err.log</string>
</dict></plist>
EOF
        place_unit "$_tmp_unit" "$LAUNCHD_DIR/com.burrowee.@UNIT_DOT@gateway.updater.plist"
        ;;

    Linux)
        # Core unit. Restart=always (not on-failure): a graceful SIGTERM exit
        # must still restart — that is the update-restart mechanism. No User=/
        # Group=/Environment=HOME=: the daemon runs as root and takes both path
        # roots as flags, so the unit body carries nothing caller-specific.
        _tmp_unit="$(mktemp)"
        cat > "$_tmp_unit" <<EOF
[Unit]
Description=burrowee-gateway
After=network-online.target

[Service]
ExecStart=$BIN_DIR/burrowee-gateway --no-open @UNIT_ROOT_ARGS@
Restart=always
RestartSec=2
TimeoutStopSec=330

[Install]
WantedBy=multi-user.target
EOF
        place_unit "$_tmp_unit" "$SYSTEMD_DIR/burrowee-@UNIT_DASH@gateway.service"

        # Updater unit. No path flags: the updater agent resolves its own roots,
        # which already default to the system pair under root's euid — the same
        # defaulting the core unit's flags only make explicit.
@BETA_ONLY_BEGIN@
        # UNDER THE BETA ROOT IT PASSES --home, and must: that defaulting knows
        # only the STABLE pair, so a beta updater without it would fetch, place
        # and restart against the other channel's tree (gateway feature 04,
        # updater_agent.RunForHome).
@BETA_ONLY_END@
        _tmp_unit="$(mktemp)"
        cat > "$_tmp_unit" <<EOF
[Unit]
Description=burrowee-gateway-updater
After=network-online.target

[Service]
ExecStart=$BIN_DIR/burrowee-gateway-updater run@UPDATER_HOME_ARGS@
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
        place_unit "$_tmp_unit" "$SYSTEMD_DIR/burrowee-@UNIT_DASH@gateway-updater.service"
        ;;

    *)
        echo "warning: unsupported OS — skipping service unit installation" >&2
        ;;
    esac
}

# $_RUNROOT / $_SYSTEMCTL — the two seams the start helpers below are
# parameterised on. Those bodies are byte-identical across the four inner
# installers and pinned that way (tools/prefix-gate-drift.test.sh), so anything
# that legitimately differs between them has to be a variable read by the body,
# never an edit to the body — and never a wrapper at the call site either, since
# `$_RUNROOT cmd` with _RUNROOT=run_root expands to a function call and a call
# site cannot reach inside the helper's own launchctl/systemctl invocations.
#
# GATEWAY HAS NO ROOT GATE. `gateway-cli` runs this script with the caller's
# privileges from `service install`, `doctor --fix` and `bootstrap`, and every
# other privileged step here goes through run_root — the start helpers must too.
# It declares no $SYSTEMCTL seam.
_RUNROOT="run_root"
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

# NOT THE SAME PARSER AS guard.sh's binary_version, AND NOT A CANDIDATE FOR
# BEING MERGED WITH IT. This helper is byte-identical with edge's (the drift
# pin described above) and filters candidate tokens through
# `grep -E '^v?[0-9]+(\.[0-9]+){0,5}(\.[0-9a-f]+)?$'`, which REJECTS a
# pre-release token: against core runtime_version.Report's two-line output the
# real stamp `v0.3.1.beta.2026.08.31.62a6f215` fails that pattern and this
# helper falls through to the SECOND line, the RUNNING daemon's version. The
# guard needs the version of the binary it just placed, on a beta build, so it
# carries its own `sed` that keeps the beta segment. Unifying the two would
# silently break the guard's restart verification on every beta host. (The beta
# blindness here is pre-existing and out of scope; it is written down at both
# sites so the next reader who notices the duplication learns why it stands.)
#
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

# ---------------------------------------------------------------------------
# load_units — (re)load the rendered SYSTEM service units (root). Separated
# from render_units so update mode can refresh the unit FILES without
# restarting services (the updater restarts the kernel out-of-band; restarting
# the updater here would bootout the very process running this script — see
# the design doc). All steps are best-effort so a supervisor-less host (e.g. a
# container) still completes the install; the unit files on disk are the
# durable outcome.
#
# BURROWEE_NO_RESTART=1 stages the units (installed/enabled) without starting
# or restarting anything already running — the local-stage counterpart to the
# gateway's `update`/`reinstall` verbs without --auto (design §4.4). Fresh
# install onto a host with nothing running yet needs at least an initial
# bootstrap/enable so the service can be started later; only the "kick a
# possibly-already-running unit" steps are skipped.
#
# NOBODY REACHES THIS ANY MORE, on gateway. The list used to read "fresh
# install and BURROWEE_UNITS_ONLY", and both have since handed their restart to
# guard.sh — the fresh path in Task 7, units-only in this change — because both
# are operator verbs run from a session that is routinely tunnelled through the
# daemon this function restarts. BURROWEE_UPDATE never called it (the process
# running this script is the one a restart here would kill mid-update; that
# exclusion is structural, not a flag — do not add a load_units call to that
# branch), and BURROWEE_UNINSTALL tears units down on its own terms.
#
# The function stays for the drift pins that make edge's and relay's still-live
# copies comparable, and for the `kickstart -k` literal
# tools/install-no-bootout.test.sh anchors to. The long note near the top of
# this file ("UNREACHABLE FROM EVERY MODE, AND KEPT ON PURPOSE") is the full
# argument; read it before deleting this.
#
# UNGATED, same as render_units and for the same reason: the units it loads are
# now written on every install, so declining to load them would leave a host
# with correct unit files and an old daemon still running.
# ---------------------------------------------------------------------------
load_units() {
    case "$(uname -s)" in
    Darwin)
        if [ -n "${BURROWEE_NO_RESTART:-}" ]; then
            # Stage only: bootstrap lays each unit in place (and fails harmlessly
            # for an already-loaded label) without booting anything out from
            # under a running instance. The two branches are exclusive — running
            # bootstrap before the bootout+bootstrap pair would start, stop, then
            # restart the service on every fresh install.
            run_root launchctl bootstrap system "$LAUNCHD_DIR/com.burrowee.@UNIT_DOT@gateway.plist"         2>/dev/null || true
            run_root launchctl bootstrap system "$LAUNCHD_DIR/com.burrowee.@UNIT_DOT@gateway.updater.plist" 2>/dev/null || true
            echo "note: BURROWEE_NO_RESTART set — units staged (not restarted)" >&2
        else
            # NO BOOTOUT. `bootout` unloads the job, and an unloaded job is not
            # supervised by anything — so a shell that dies between the bootout
            # and the bootstrap below leaves the daemon stopped with nothing
            # that will restart it. On a gateway that shell death is CAUSED by
            # the bootout: the operator's session reaches this host through the
            # daemon being unloaded. Observed on a live host 2026-08-31; the
            # install stopped mid-sequence and doctor then reported "service
            # not installed (launchd)" about a host that had been serving.
            #
            # start_unit_darwin's `kickstart -k` is the whole restart. It
            # advances a LOADED job to the freshly placed binary without ever
            # passing through an unloaded state, so no window exists in which a
            # dying shell can strand the host. The bootstrap it runs first is
            # what loads the job on a host that has none, and exits 5
            # ("already loaded") harmlessly on one that does — which is exactly
            # the case the deleted bootout was manufacturing.
            start_unit_darwin "com.burrowee.@UNIT_DOT@gateway" "$LAUNCHD_DIR/com.burrowee.@UNIT_DOT@gateway.plist"
            SERVE_UNIT_STARTED=1
            if [ -n "${BURROWEE_NO_UPDATER:-}" ]; then
                echo "note: BURROWEE_NO_UPDATER set — updater unit staged, not started" >&2
            else
                run_root launchctl bootout "system/com.burrowee.@UNIT_DOT@gateway.updater" 2>/dev/null || true
                # Recorded, not fatal — see UPDATER_START_FAILED.
                start_unit_darwin "com.burrowee.@UNIT_DOT@gateway.updater" "$LAUNCHD_DIR/com.burrowee.@UNIT_DOT@gateway.updater.plist" \
                    || UPDATER_START_FAILED=1
            fi
        fi
        ;;
    Linux)
        run_root systemctl daemon-reload 2>/dev/null || true
        if [ -n "${BURROWEE_NO_RESTART:-}" ]; then
            run_root systemctl enable burrowee-@UNIT_DASH@gateway.service         2>/dev/null || true
            run_root systemctl enable burrowee-@UNIT_DASH@gateway-updater.service 2>/dev/null || true
            echo "note: BURROWEE_NO_RESTART set — units staged (not restarted)" >&2
        else
            run_root systemctl enable --now burrowee-@UNIT_DASH@gateway.service         2>/dev/null || true

            # THE DAEMON, ADVANCED — the step this branch was missing, and the
            # reason a Linux host kept executing its OLD ExecStart until the next
            # reboot. `enable --now` no-ops a unit that is already running, so on
            # every reinstall the privileged-tree unit was written correctly and
            # then simply not obeyed: `doctor` reported installed-vs-running
            # drift, and the security fix the rewrite exists for (a root unit
            # naming a per-user path) silently did not take effect. Darwin's
            # bootout+bootstrap pair above has always done this; the edge
            # installer does it too (`systemctl restart burrowee-edge`). Gateway
            # on Linux was the one component that stopped at "files on disk".
            #
            # `restart` is the systemd spelling of bootout+bootstrap: stop it if
            # it is running, then start it. Not `try-restart`, which leaves a unit
            # that is enabled-but-stopped stopped and still exits 0 — reporting
            # success for the one state the operator most needs told about. Not
            # `reload-or-restart` either: it prefers ExecReload, so the day this
            # unit grows one, "the daemon now runs the new binary" would silently
            # become "the old process re-read its config" — this exact bug, back,
            # wearing the fix's name.
            #
            # UNCONDITIONAL, on purpose. The tempting guard — restart only when a
            # binary or the unit body actually changed — cannot see the state that
            # created this bug: files already converged, process still stale. A
            # host in drift today reaches `@DISPATCHER@ gateway service install` with
            # every byte already in place, so a change-detecting restart would
            # decline exactly when the operator ran the documented remedy. It is
            # also not a spontaneous bounce: nothing periodic reaches here (see
            # which modes call load_units at all, below), and the two that do are
            # operator-initiated install verbs.
            #
            # Loud on failure. New binaries under an old daemon is the one
            # outcome that looks like a clean install and is not, so it is never
            # swallowed. `restart`'s own status is a diagnosis, not the verdict:
            # it is funnelled into the probe below the same way start_unit_linux
            # funnels enable/restart into its is-active check.
            if ! run_root systemctl restart burrowee-@UNIT_DASH@gateway.service; then
                echo "error: 'systemctl restart burrowee-@UNIT_DASH@gateway.service' failed — the newly" >&2
                echo "error: installed binaries are on disk, but the daemon still running is the" >&2
                echo "error: OLD one. '@DISPATCHER@ gateway doctor' reports installed/running drift" >&2
                echo "error: until it is restarted, and a unit rewritten to a new ExecStart has" >&2
                echo "error: not taken effect." >&2
                echo "hint: restart it by hand: sudo systemctl restart burrowee-@UNIT_DASH@gateway.service" >&2
            fi

            # THE PROBE — gateway on Linux was the last component/platform pair
            # without one, and the only place the policy "an installer that exits
            # 0 has left the component running" (design rule 3) still did not
            # hold. `enable --now` reports success for a unit whose ExecStart dies
            # on start, and `restart` exiting 0 says the transaction was accepted,
            # not that the daemon is up a moment later. Only is-active answers the
            # question the install's exit status is claiming to answer.
            #
            # FATAL, like every other serve start in the tree: start_unit_linux
            # and start_unit_darwin both return 1 here, and load_units is called
            # unguarded under `set -e`. A container with no systemd never reaches
            # this branch with an enabled unit to begin with — it fails at
            # daemon-reload's `|| true` and has no unit to probe.
            #
            # THE FLAG IS ARMED FROM THE PROBE, not from restart's status: a
            # daemon that starts and dies a second later would otherwise arm the
            # 60s wait for a version it can never report.
            if run_root systemctl is-active --quiet burrowee-@UNIT_DASH@gateway.service; then
                echo "systemd service burrowee-@UNIT_DASH@gateway.service enabled + (re)started"
                SERVE_UNIT_STARTED=1
            else
                echo "error: burrowee-@UNIT_DASH@gateway.service is not active after enable --now" >&2
                echo "hint: sudo systemctl status burrowee-@UNIT_DASH@gateway.service" >&2
                return 1
            fi

            # A reinstall over an already-running (possibly stale) updater must advance
            # it to the freshly-installed binary — `enable --now` no-ops a running unit,
            # so restart it explicitly. Otherwise the stale updater keeps running old
            # code and future pushes deadlock. (load_units is never called on the
            # updater's own push path — BURROWEE_UPDATE renders units without loading
            # them — so this can never self-kill. The Darwin branch above already
            # advances the updater via its bootout+bootstrap.)
            if [ -n "${BURROWEE_NO_UPDATER:-}" ]; then
                echo "note: BURROWEE_NO_UPDATER set — updater unit staged, not started" >&2
            else
                # Recorded, not fatal — see UPDATER_START_FAILED.
                start_unit_linux burrowee-@UNIT_DASH@gateway-updater.service || UPDATER_START_FAILED=1
            fi
        fi
        ;;
    esac
}

# ---------------------------------------------------------------------------
# finish_with_updater_verdict — the last statement of every mode that calls
# load_units, of which there are now none: it goes unreachable with load_units
# itself (see that function's header, and the top-of-file note). The updater
# start it reports on happens in the guard now (guard.sh's advance_updater,
# after a verified restart), where this shell cannot observe it and reattach's
# verdict already covers the whole install.
#
# Exits 0 when the updater started (or was never asked to), and 1 when its
# start failed, having let everything after load_units run first.
#
# It is an exit and not a `return 1` because the whole point is that it happens
# AFTER the state-recording work and the doctor tail: a `set -e` abort at the
# start itself is exactly the behaviour this replaces.
# ---------------------------------------------------------------------------
finish_with_updater_verdict() {
    if [ "$UPDATER_START_FAILED" = 1 ]; then
        echo "error: the gateway updater unit did not start — this host will not receive" >&2
        echo "error: automatic updates until it does. Everything else completed: the serve" >&2
        echo "error: daemon was verified up, the version anchor was recorded, and doctor's" >&2
        echo "error: report is above. The start's own error names the unit and the command." >&2
        echo "hint: sudo curl -fsSL https://release.burrowee.com/gateway/updater.install.sh | sh" >&2
        exit 1
    fi
    exit 0
}

# ---------------------------------------------------------------------------
# sha256_of — portable sha256 digest of a file (shasum on darwin, sha256sum on linux).
# ---------------------------------------------------------------------------
sha256_of() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else echo "sha256_of: no shasum or sha256sum found" >&2; exit 1; fi
}

# ---------------------------------------------------------------------------
# The install transaction.
#
# ONE directory holds everything the guard needs to finish, or undo, an install
# that the operator's session did not survive. It lives under the DATA root
# because that is the root the guard can reach as root on every platform, and
# because it must outlive both the installer process and the session.
#
#   $SYS_DATA_DIR/install/<stamp>/
#     phase          one token, the state machine's whole shared state
#     manifest       key=value: what was snapshotted, and how faithfully
#     guard.log      the guard's own narration
#     guard.pid      the live-guard marker guard_refuse_concurrent reads, so a
#                    second install refuses rather than booting out a guard
#                    that may be mid-rollback
#     installer.pid  what the guard watches for an early death
#     heartbeat      UTC epoch, refreshed while this script sits on a blocking
#                    prompt, so the guard's deadline measures a WEDGE and not
#                    an operator who stepped away (txn_heartbeat)
#     units-changed  basenames of unit files this run actually rewrote, so the
#                    guard knows a kickstart is not enough (place_unit)
#     snapshot/      bin/ units/ config/ data/
# ---------------------------------------------------------------------------
TXN_DIR=""
TXN_STAMP=""
# GUARD_ARMED — THREE VALUES, not two, because there are three states and
# collapsing them lost a host.
#
#   0          no guard was armed at all (BURROWEE_NO_RESTART, or guard_arm
#              refused). Nothing will restart, and the foreground restore in
#              abort_install is the only undo there is.
#   1          guard_arm handed the guard to the supervisor AND guard_prove_armed
#              saw it start. A guard is watching; the foreground restore is the
#              WRONG undo, because it copies files and never restarts.
#   unproven   the supervisor accepted the guard and guard_prove_armed could not
#              READ the transaction to tell whether it started — a root-owned
#              0700 tree and a host whose sudoers refuses every `sudo -n`
#              (timestamp_timeout=0). The install continues, because a blind read
#              is not evidence of a dead guard; but nothing downstream may ASSUME
#              a guard will clean up.
#
# `unproven` used to be spelled `1`. guard_prove_armed's fail-open returned 0 and
# guard_arm set the flag regardless, so a host where the guard was genuinely dead
# ran the whole install claiming one was watching — and a later abort_install
# handed its undo to that guard, printing "the guard is undoing this install"
# about nothing at all, restoring nothing, restarting nothing. Fail-open is still
# right (see guard_prove_armed); asserting a guard exists is what was wrong.
GUARD_ARMED=0

txn_begin() {
    TXN_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
    TXN_DIR="$SYS_DATA_DIR/install/$TXN_STAMP"
    # THIS IS NOW THE FIRST THING THAT CREATES $SYS_DATA_DIR, and that is why
    # the mode of the DATA ROOT is set here rather than left to whoever gets
    # there first.
    #
    # ensure_system_log_dir owns the 0700 rule for that root, and it applies it
    # only when it created the root itself ("_data_root_existed") — correct,
    # because re-tightening a root an operator already has is not this
    # installer's call. But the transaction moved ahead of it: `mkdir -p
    # $SYS_DATA_DIR/install/<stamp>` creates $SYS_DATA_DIR as a side effect,
    # with the caller's umask, and ensure_system_log_dir then finds it already
    # there and leaves it alone. On a host with a permissive umask that is a
    # data root at 0775 — holding gateway.db and the register/console sockets —
    # created that way by every guarded install, which is exactly the outcome
    # the 0700 rule exists to make impossible.
    #
    # So the same rule, applied by the function that now creates it first: note
    # whether the root was there before, and tighten only what this call
    # brought into existence. ensure_system_log_dir keeps its own copy of the
    # test for the paths that reach it without a transaction.
    _txn_data_root_existed=0
    if [ -d "$SYS_DATA_DIR" ]; then _txn_data_root_existed=1; fi
    run_root mkdir -p "$TXN_DIR/snapshot/bin" "$TXN_DIR/snapshot/units" || return 1
    if [ "$_txn_data_root_existed" = 0 ]; then
        run_root chmod 0700 "$SYS_DATA_DIR" 2>/dev/null || true
    fi
    run_root chmod 700 "$SYS_DATA_DIR/install" "$TXN_DIR" || return 1
    printf '%s\n' "$$" | run_root tee "$TXN_DIR/installer.pid" >/dev/null || return 1
    txn_phase armed
}

# ---------------------------------------------------------------------------
# Reading back out of the transaction, from a possibly-unprivileged shell.
#
# txn_begin creates the transaction ROOT-OWNED AND 0700, and this script is
# routinely entered by an unprivileged shell that elevates per command
# (run_root). So a plain `cat`, `ls` or `[ -f ]` inside that tree answers
# "nothing there" about files that plainly exist — and every caller below turns
# that into a wrong conclusion: reattach reports "the guard has not reported
# yet" about a guard that reported minutes ago, guard_prove_armed refuses a
# guard that started fine, guard_refuse_concurrent cannot see a live guard at
# all.
#
# `sudo -n` and never plain `sudo`: these all sit on paths that must not grow a
# password prompt (one is polled in a loop). A refused elevation falls back to
# the same empty answer the unprivileged read already gave, so the degradation
# is exactly today's behaviour and never a hang.
# ---------------------------------------------------------------------------
txn_read_file() {
    if [ "$(id -u)" = 0 ]; then
        cat "$1" 2>/dev/null || true
        return 0
    fi
    cat "$1" 2>/dev/null || sudo -n cat "$1" 2>/dev/null || true
}

txn_list_dir() {
    if [ "$(id -u)" = 0 ]; then
        ls -1 "$1" 2>/dev/null || true
        return 0
    fi
    ls -1 "$1" 2>/dev/null || sudo -n ls -1 "$1" 2>/dev/null || true
}

txn_file_exists() {
    [ -f "$1" ] && return 0
    [ "$(id -u)" = 0 ] && return 1
    sudo -n test -f "$1" 2>/dev/null
}

txn_read_phase() {
    [ -n "$TXN_DIR" ] || return 0
    txn_read_file "$TXN_DIR/phase"
}

# txn_phase <phase> — the ONLY writer of the phase file, and it writes
# atomically. The guard polls this file; a partial write read as a phase name
# would be an unrecognised state, and the guard's default for an unrecognised
# state is to roll back. Write to a temp name in the same directory, then mv.
#
# IT WILL NOT OVERWRITE A TERMINAL PHASE. Once the guard has written ok,
# rolled-back, aborted or failed, the transaction is over and the guard process
# is gone.
# A later `txn_phase handoff` from a still-live installer — which is exactly
# what an operator returning to a prompt after the guard's deadline fired
# produces — would hand the restart to a process that has exited: nothing
# restarts, reattach polls a phase file nothing will advance, gives up, and the
# install exits 0 over a partially undone host. Refusing the write leaves the
# guard's real verdict in place, which is what reattach then reports.
#
# It returns 0 on that refusal, deliberately: every call site is a bare
# statement under `set -e`, and aborting the script here would skip the doctor
# tail and reattach's verdict — the two things that tell the operator what
# actually happened.
txn_phase() {
    [ -n "$TXN_DIR" ] || return 0
    case "$(txn_read_phase)" in
    ok | rolled-back | aborted | failed)
        echo "install: the guard has already finished this transaction (phase" >&2
        echo "install: $(txn_read_phase)) — not overwriting it with '$1'." >&2
        return 0
        ;;
    esac
    printf '%s\n' "$1" | run_root tee "$TXN_DIR/.phase.tmp" >/dev/null || return 1
    run_root mv -f "$TXN_DIR/.phase.tmp" "$TXN_DIR/phase" || return 1
}

# ---------------------------------------------------------------------------
# The prompt heartbeat.
#
# The guard's 900s deadline is a WEDGE DETECTOR, and it stopped being one the
# moment the install grew blocking prompts: the clock starts at Phase 0 and
# spans both the setup blob/PIN prompt and the consent prompt. An operator who
# steps away at `blob>` gets the guard rolling back underneath a live
# installer, which then writes phase=handoff to a guard that has already
# exited. (txn_phase's terminal-phase refusal above is the second half of that
# fix; this is the first.)
#
# txn_heartbeat writes a UTC epoch the guard measures its deadline from
# instead. It is BEST-EFFORT AND NEVER PROMPTS — `sudo -n`, all output
# discarded, `|| true` — because a heartbeat that can block on a password
# prompt blocks on the very thing it exists to measure. A host where it cannot
# write simply behaves as it did before: the deadline runs from Phase 0.
#
# heartbeat_start / heartbeat_stop bracket a blocking read with a background
# ticker, because refreshing before and after a `read` says nothing about the
# hours in between. The ticker is a plain subshell job: it dies with this
# script's session, which is correct — a severed session is a dead installer,
# and the guard's installer-died branch owns that case, not the deadline.
# ---------------------------------------------------------------------------
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-10}"
[ "$HEARTBEAT_INTERVAL" -gt 0 ] 2>/dev/null || HEARTBEAT_INTERVAL=10
HEARTBEAT_PID=""

txn_heartbeat() {
    [ -n "$TXN_DIR" ] || return 0
    if [ "$(id -u)" = 0 ]; then
        date -u +%s > "$TXN_DIR/heartbeat" 2>/dev/null || true
        return 0
    fi
    date -u +%s > "$TXN_DIR/heartbeat" 2>/dev/null && return 0
    date -u +%s | sudo -n tee "$TXN_DIR/heartbeat" >/dev/null 2>&1 || true

}

heartbeat_start() {
    [ -n "$TXN_DIR" ] || return 0
    [ -z "$HEARTBEAT_PID" ] || return 0
    txn_heartbeat
    ( while :; do sleep "$HEARTBEAT_INTERVAL"; txn_heartbeat; done ) >/dev/null 2>&1 &
    HEARTBEAT_PID=$!
}

heartbeat_stop() {
    [ -n "$HEARTBEAT_PID" ] || return 0
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    wait "$HEARTBEAT_PID" 2>/dev/null || true
    HEARTBEAT_PID=""
    txn_heartbeat
}

# snapshot_take — capture the last working point: binaries, units, config tree,
# state tree. Runs BEFORE the first write, while the old daemon is still
# serving, so everything here is a read of a live host.
snapshot_take() {
    _snap="$TXN_DIR/snapshot"

    for b in $BINS; do
        if [ -f "$BIN_DIR/$b" ]; then
            run_root cp -p "$BIN_DIR/$b" "$_snap/bin/$b" || return 1
        fi
    done

    case "$(uname -s)" in
    Darwin)
        for u in com.burrowee.@UNIT_DOT@gateway.plist com.burrowee.@UNIT_DOT@gateway.updater.plist; do
            [ -f "$LAUNCHD_DIR/$u" ] && { run_root cp -p "$LAUNCHD_DIR/$u" "$_snap/units/$u" || return 1; }
        done
        ;;
    Linux)
        for u in burrowee-@UNIT_DASH@gateway.service burrowee-@UNIT_DASH@gateway-updater.service; do
            [ -f "$SYSTEMD_DIR/$u" ] && { run_root cp -p "$SYSTEMD_DIR/$u" "$_snap/units/$u" || return 1; }
        done
        ;;
    esac

    # The config tree whole — the identity key is in here, and losing it is
    # unrecoverable, so it is snapshotted for the same reason it is never
    # regenerated.
    if [ -d "$SYS_CONFIG_DIR" ]; then
        run_root cp -Rp "$SYS_CONFIG_DIR" "$_snap/config" || return 1
    fi

    # The state tree, MINUS install/ (this directory — copying it into itself
    # is unbounded) and MINUS logs/ (large, append-only, and restoring an old
    # log is not part of any working point).
    run_root mkdir -p "$_snap/data" || return 1
    if [ -d "$SYS_DATA_DIR" ]; then
        for _e in "$SYS_DATA_DIR"/*; do
            [ -e "$_e" ] || continue
            case "${_e##*/}" in
                install | logs) continue ;;
                gateway.db | gateway.db-wal | gateway.db-shm) continue ;;  # handled below
            esac
            run_root cp -Rp "$_e" "$_snap/data/" || return 1
        done
    fi

    snapshot_db "$_snap/data/gateway.db"

    _running="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$SYS_DATA_DIR/running.json" 2>/dev/null || true)"
    {
        printf 'stamp=%s\n'           "$TXN_STAMP"
        printf 'running_version=%s\n' "${_running:-unknown}"
        printf 'uname=%s\n'           "$(uname -s)"
        printf 'consistency=%s\n'     "$SNAPSHOT_CONSISTENCY"
    } | run_root tee "$TXN_DIR/manifest" >/dev/null || return 1
}

# snapshot_db <dst> — a CONSISTENT copy of gateway.db, taken while the old
# daemon still holds it open. gateway.db is WAL-mode, so a plain cp under an
# active writer can capture a header that does not match the pages beside it;
# restoring that is worse than not rolling back, because the guard would
# "recover" the host onto a store that will not open. Three ways down, best
# first, and the manifest records which one was used.
#
# THREE VALUES, NOT TWO: exact · best-effort · no-database.
#
# The early return below fires on every host that has never run a gateway, and
# it used to leave this variable at its initial `exact` — so the manifest
# claimed an exact database copy for a run that captured no database at all,
# and `guard-status` printed that claim verbatim to the operator. The value is
# only ever set here now: this function is the sole writer, and every one of
# its exits says what it actually did.
#
# `consistency` is a MANIFEST FIELD, not a phase. guard-status prints it
# through as free text (gateway's guard_status.go: `if c := txn.Manifest
# ["consistency"]; c != ""`), with no vocabulary to keep in step — unlike the
# phase tokens, a new value here needs nothing changed in the gateway repo.
SNAPSHOT_CONSISTENCY=exact
snapshot_db() {
    _dst="$1"
    if [ ! -f "$SYS_DATA_DIR/gateway.db" ]; then
        SNAPSHOT_CONSISTENCY=no-database
        return 0
    fi

    if run_root "$BIN_DIR/burrowee-gateway-cli" db snapshot "$_dst" 2>/dev/null; then
        SNAPSHOT_CONSISTENCY=exact
        return 0
    fi
    if command -v sqlite3 >/dev/null 2>&1 &&
       run_root sqlite3 "$SYS_DATA_DIR/gateway.db" ".backup '$_dst'" 2>/dev/null; then
        SNAPSHOT_CONSISTENCY=exact
        return 0
    fi
    # Last resort: the database and BOTH sidecars together, so the pair can at
    # least be reconciled by SQLite on open. Recorded honestly.
    for _f in gateway.db gateway.db-wal gateway.db-shm; do
        [ -f "$SYS_DATA_DIR/$_f" ] && run_root cp -p "$SYS_DATA_DIR/$_f" "${_dst%gateway.db}$_f"
    done
    SNAPSHOT_CONSISTENCY=best-effort
    echo "warning: gateway.db was copied without an online backup — a rollback may" >&2
    echo "warning: restore a database that needs recovery on open (consistency=best-effort)" >&2
}

# ---------------------------------------------------------------------------
# THE SAME QUESTION guard.sh's snapshot_has_binaries asks — "is there a
# previous install behind this snapshot at all" — asked from the OTHER side of
# a privilege boundary, and answered with one more state because from here
# there is one more thing that can be true.
#
# WHY NOT ONE BODY IN BOTH FILES. It was, byte for byte, and the pin that held
# it there was itself recorded as standing in the way of this fix. The guard
# runs as ROOT, execed by launchd/systemd: a bare `[ -d ]` and a glob are a
# complete answer for it, and it has no elevated-read helper to reach for.
# install.sh is routinely entered by an UNPRIVILEGED shell that elevates per
# command, and txn_begin makes the transaction root-owned 0700 — which is the
# whole reason txn_read_file / txn_list_dir / txn_file_exists exist. The shared
# body used neither, so from here it could answer "no binaries" out of pure
# blindness, and abort_install's prose then told the operator a fact about
# their host ("this host had no previous gateway install") that this shell had
# not established and could not have.
#
# So the duplication ends rather than being re-pinned: two readers with
# genuinely different powers get two predicates, and the test that used to
# demand byte-identity now demands the thing that actually matters — that on a
# snapshot BOTH can see, the two answer the same
# (tools/guard-rollback.test.sh, t_snapshot_binaries_predicates_agree).
#
# THE THIRD STATE IS THE POINT. "No binaries" and "I could not look" are
# different facts about a host, and only one of them licenses the sentence
# "there was nothing to restore".
# ---------------------------------------------------------------------------
# snapshot_binaries_state <snapshot-dir> — prints one of:
#
#   some     the snapshot holds at least one previous binary
#   none     it was READ, and it holds none — the empty shell a fresh host
#            produces, because snapshot_take copies only names that were
#            already in $BIN_DIR (`[ -f "$BIN_DIR/$b" ]`)
#   unknown  this shell cannot see into the transaction at all
#
# `none` and `unknown` are told apart by the SNAPSHOT DIRECTORY ITSELF, and it
# is a discriminator this script guarantees rather than hopes for: txn_begin
# creates `snapshot/bin` and `snapshot/units` before anything else happens, so
# a snapshot dir that lists as empty is not a fresh host — it is a shell that
# cannot read the directory. That is the same shape guard_prove_armed uses
# installer.pid for, for the same reason: a file that CERTAINLY exists is what
# turns an empty answer into evidence.
#
# txn_list_dir and not a glob: it is the helper that degrades to `sudo -n`,
# which is what makes the common unprivileged install answer `some`/`none`
# instead of `unknown`. Its own header explains why the elevation is
# non-interactive.
snapshot_binaries_state() {
    if [ -n "$(txn_list_dir "$1/bin")" ]; then printf 'some\n'; return 0; fi
    if [ -n "$(txn_list_dir "$1")" ]; then printf 'none\n'; return 0; fi
    printf 'unknown\n'
}

# snapshot_restore — put the last working point back. Every failure is
# reported and the function keeps going: a partial restore that gets the
# binaries back is strictly better than one that stops at the first error.
snapshot_restore() {
    _snap="$TXN_DIR/snapshot"
    _rc=0

    for b in $BINS; do
        [ -f "$_snap/bin/$b" ] || continue
        run_root cp -p "$_snap/bin/$b" "$BIN_DIR/$b" || _rc=1
    done

    # The same mapping guard.sh's unit_dir() holds, off the same two
    # environment defaults (LAUNCHD_DIR / SYSTEMD_DIR, install.sh:204-206;
    # guard.sh resolves BURROWEE_LAUNCHD_DIR / BURROWEE_SYSTEMD_DIR into names
    # spelled identically). Two files restore the same unit files, so the two
    # must agree — they used to agree only by coincidence, under different
    # variable names and with the defaults written out inline on the guard's
    # side. Change either seam and change both.
    case "$(uname -s)" in
    Darwin) _unit_dir="$LAUNCHD_DIR" ;;
    Linux)  _unit_dir="$SYSTEMD_DIR" ;;
    *)      _unit_dir="" ;;
    esac

    if [ -n "$_unit_dir" ] && [ -d "$_snap/units" ]; then
        for _u in "$_snap/units"/*; do
            [ -e "$_u" ] || continue
            run_root cp -p "$_u" "$_unit_dir/${_u##*/}" || _rc=1
        done
    fi

    [ -d "$_snap/config" ] && { run_root cp -Rp "$_snap/config/." "$SYS_CONFIG_DIR/" || _rc=1; }
    [ -d "$_snap/data" ]   && { run_root cp -Rp "$_snap/data/."   "$SYS_DATA_DIR/"   || _rc=1; }

    return "$_rc"
}

# ---------------------------------------------------------------------------
# guard_arm — hand the guard to the SUPERVISOR, not to this shell.
#
# `nohup … &` would make the guard a descendant of sshd's session. That
# survives SIGHUP and nothing else: when the session's process group or cgroup
# is torn down — which is what a dropped tunnel does — the guard goes with it,
# at exactly the moment it is needed. launchd and systemd are the two processes
# on this host guaranteed to outlive the session, so the guard runs under one
# of them or it is not armed at all.
#
# Root is taken HERE, in the foreground, where run_root can still prompt on the
# operator's tty. The guard itself can never prompt for anything.
#
# THE GUARD IS EXECED AS ROOT, so the path handed to the supervisor is a
# root-exec surface and gets the same treatment as every other one in this
# file: placed into $BIN_DIR and PROVEN root-secure before the unit names it.
#
# It used to be copied into a freshly created /usr/local/libexec/burrowee and
# run from there, unchecked at both ends. Neither end was safe. The SOURCE was
# "$(dirname "$0")/guard.sh", which for a default-mode re-run of the kept
# $GW_HOME/install.sh is the OPERATOR-WRITABLE copy keep_installer_copy leaves
# under $HOME — the very path guard.sh's own header argues must never be
# sourced as root. And the DESTINATION was never walked by path_is_root_secure,
# so on an Intel macOS host where Homebrew chowns /usr/local it was a
# user-writable path a root LaunchDaemon execs at every arm.
#
# So the libexec destination is GONE, not merely checked. $BIN_DIR is the
# surface ensure_root_exec_surface already places into and
# verify_root_exec_surface already walks; recreating the retired libexec tree
# for one file would be a second root-exec surface with its own placement, its
# own verification and its own uninstall — three things to keep in step where
# zero were needed. That is the same collapse this file's header describes for
# the binaries, applied to the last artefact that had escaped it.
#
# The SOURCE is still resolved beside THIS installer, and that is deliberate:
# it is the unpacked payload the outer bootstrap signature-verified, the same
# resolution ensure_root_exec_surface uses for migrations/ and $0. The
# difference is that it is now copied to $BIN_DIR **as root** and the copy is
# what runs — so an operator-writable source can only ever put content there
# through an elevated install, never be execed in place.
#
# THE REFUSALS ARE THE POINT. No guard.sh beside the installer, a $BIN_DIR copy
# that does not pass the root-secure walk, an unsupported platform, or a guard
# that never actually started: each aborts before Phase 1's first write, with
# the old install untouched and the snapshot already taken.
guard_arm() {
    # ---- BURROWEE_NO_RESTART=1: stage without arming a restart -------------
    #
    # It had exactly two readers, both inside load_units, and the default path
    # stopped calling load_units when Task 7 handed the restart to the guard —
    # so on the one path an operator is most likely to set it, the flag became
    # a silent no-op: this function armed anyway, `txn_phase handoff` fired
    # anyway, and the guard restarted the daemon anyway. This file's own
    # documentation of the flag (load_units' header, and the design) said the
    # opposite the whole time.
    #
    # BURROWEE_UNITS_ONLY reaches this too now, and reads the same. It used to
    # honour the flag through load_units' own staging branch — a `bootstrap` /
    # `enable` without the kick — which was a WEAKER promise than the one the
    # flag makes: on Darwin a `bootstrap` of a RunAtLoad plist starts the
    # daemon. Both paths now leave the units rendered and unloaded, which is
    # the promise.
    #
    # Honouring it means not arming here and not handing off later; the caller
    # reads GUARD_ARMED for the second half. The transaction and the snapshot
    # are still taken — they cost a copy, they are what `guard-status` reads
    # afterwards, and they are what abort_install restores from when a Phase 2
    # check fails with no guard to hand the undo to.
    #
    # The units are left RENDERED and not loaded, because loading them is what
    # STARTS them: a Darwin `bootstrap` on a RunAtLoad plist starts the daemon,
    # which is the one thing this flag asks not to happen.
    #
    # The check lives here rather than at the call site so that the call stays
    # a bare `guard_arm` at column 0 — the anchor
    # tools/install-guard-arms-first.test.sh uses to prove the arming still
    # precedes migrate_from_legacy.
    #
    # AND THE MESSAGE SAYS WHAT THE FLAG ACTUALLY CONTROLS. It used to promise
    # that "nothing will be restarted", which is a claim about the HOST and not
    # about this script. On Darwin the serve plist this installer writes carries
    #   KeepAlive → PathState → $BIN_DIR/burrowee-gateway
    # (render_units), so on a host where the label is already loaded, replacing
    # that binary stops the running job the moment the path goes away and
    # launchd starts it again the moment the new one appears — no restart verb
    # is involved, and nothing here can suppress it. An operator who set this
    # flag because a restart was unacceptable had been told the opposite of what
    # they would observe.
    if [ -n "${BURROWEE_NO_RESTART:-}" ]; then
        echo "note: BURROWEE_NO_RESTART set — the install guard is NOT armed and this" >&2
        echo "note: installer restarts nothing; the units are written to disk and left" >&2
        echo "note: staged." >&2
        echo "note: on macOS that is not the same as 'the daemon will not restart': the serve" >&2
        echo "note: plist's KeepAlive.PathState watches $BIN_DIR/burrowee-gateway, so a job" >&2
        echo "note: launchd has already loaded stops when that binary is replaced and is" >&2
        echo "note: started again as soon as the new one is in place." >&2
        return 0
    fi

    _guard_src="$(dirname "$0")/guard.sh"

    if [ ! -f "$_guard_src" ]; then
        echo "error: guard.sh is not beside this installer — refusing to run an unguarded" >&2
        echo "error: install on a host that is currently serving as a gateway." >&2
        return 1
    fi

    guard_refuse_concurrent || return 1

    # THROUGH THE SAME ONE ELEVATION DECISION every other $BIN_DIR write uses,
    # never a bare run_root. This is the first write into $BIN_DIR on a fresh
    # run, and blanket-elevating it would re-introduce exactly what
    # decide_bin_place_elevated exists to prevent: a host whose /usr/local this
    # user already owns (Homebrew on an Intel Mac, a container running as
    # itself) paying for a sudo call it does not need — and, where sudo is
    # unavailable, failing an install that would otherwise have completed.
    decide_bin_place_elevated
    guard_place_failed() {
        echo "install: cannot write $BIN_DIR — no binary was placed." >&2
        echo "install: the install guard is placed there too, because launchd/systemd exec it" >&2
        echo "install: as root, and an unguarded install on a serving gateway is the failure" >&2
        echo "install: this installer exists to prevent." >&2
        echo "install: re-run as root, or grant this user sudo." >&2
    }
    # `[ -d ]` first: decide_bin_place_elevated has already tried an
    # unprivileged mkdir -p, so an existing directory needs no second one — and
    # elevating a mkdir for a directory that is already there is a sudo call
    # bought for nothing.
    if [ ! -d "$BIN_DIR" ] && ! bin_place_run mkdir -p "$BIN_DIR"; then
        guard_place_failed
        return 1
    fi
    if [ ! -f "$BIN_DIR/guard.sh" ] || ! cmp -s "$_guard_src" "$BIN_DIR/guard.sh"; then
        bin_place_run /usr/bin/install -m 0755 "$_guard_src" "$BIN_DIR/guard.sh" || {
            guard_place_failed
            return 1
        }
    fi
    _guard="$BIN_DIR/guard.sh"

    # Same gate verify_root_exec_surface applies to itself: ownership can only
    # be asserted where elevation actually yields uid 0, and the sandboxed
    # harness's pass-through `sudo` stub leaves every "root" file owned by the
    # test user. Asking the elevation path who it is keeps the production
    # assertion strict without a second env seam.
    #
    # rc 1 (insecure) and rc 2 (undecidable) are DIFFERENT REFUSALS, exactly as
    # in verify_root_exec_surface, which this block imitated without inheriting
    # the split. Both refuse — a path handed to root must fail closed either
    # way — but "check your permissions" sends an operator to a tree that may
    # be perfectly correct, when the real fault is that this host's `stat`
    # answered neither dialect. That conflation is what the stat-dialect bug
    # actually cost the last time, and it is written down in
    # path_is_root_secure's own header for that reason.
    if have_real_root; then
        _guard_rc=0
        path_is_root_secure "$_guard" || _guard_rc=$?
        if [ "$_guard_rc" = 2 ]; then
            echo "error: could not read the owner and mode of $_guard — this host's 'stat'" >&2
            echo "error: answered neither the GNU form (stat -c '%u') nor the BSD form" >&2
            echo "error: (stat -f '%u') with a plain number." >&2
            echo "error: launchd/systemd execs the install guard AS ROOT, so refusing to arm it" >&2
            echo "error: out of a path whose ownership could not be established." >&2
            echo "hint: the permissions of $BIN_DIR are NOT implicated — reading them is." >&2
            echo "hint: check which stat is on PATH ('command -v stat') and that it is the" >&2
            echo "hint: system one, then re-run." >&2
            echo "hint: nothing has been written yet; the running install is untouched." >&2
            return 1
        elif [ "$_guard_rc" = 3 ]; then
            echo "error: $_guard does not exist — the copy this run just placed is not there." >&2
            echo "error: launchd/systemd execs the install guard AS ROOT, so refusing to arm a" >&2
            echo "error: path with nothing at it." >&2
            echo "hint: check that $BIN_DIR is writable by this install and not on a" >&2
            echo "hint: read-only or full filesystem." >&2
            echo "hint: nothing has been written yet; the running install is untouched." >&2
            return 1
        elif [ "$_guard_rc" != 0 ]; then
            echo "error: $_guard is not root-owned and unwritable all the way to /." >&2
            echo "error: launchd/systemd execs the install guard AS ROOT, so refusing to arm" >&2
            echo "error: it out of a path a non-root user could replace." >&2
            echo "hint: check the ownership and modes of $BIN_DIR and every directory above" >&2
            echo "hint: it; each must be owned by root and not group- or world-writable." >&2
            return 1
        fi
    fi

    case "$(uname -s)" in
    Darwin)
        _gp="$LAUNCHD_DIR/com.burrowee.@UNIT_DOT@gateway.guard.plist"
        _tmp="$(mktemp)"
        cat > "$_tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.burrowee.@UNIT_DOT@gateway.guard</string>
  <key>ProgramArguments</key><array><string>$_guard</string><string>$TXN_DIR</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>WorkingDirectory</key><string>/tmp</string>
  <key>RunAtLoad</key><true/>
  <key>AbandonProcessGroup</key><true/>
  <key>StandardOutPath</key><string>$TXN_DIR/guard.out</string>
  <key>StandardErrorPath</key><string>$TXN_DIR/guard.err</string>
</dict></plist>
EOF
        # place_unit, not a bare install: it is what records a changed unit
        # body into the transaction (see place_unit). The guard filters that
        # marker by unit NAME, so its own plist appearing there is inert.
        place_unit "$_tmp" "$_gp"
        # No KeepAlive, and the guard removes this plist itself on every exit
        # path (guard.sh's remove_guard_unit) — a RunAtLoad plist left behind
        # re-runs the guard against a finished transaction at every boot.
        # bootout FIRST, because unlike the serve label this one is safe to
        # unload — nothing routes through it — and a stale guard job from a
        # previous install would otherwise refuse the bootstrap.
        # guard_refuse_concurrent above has already proved no LIVE guard is
        # mid-flight, so this can never unload one in the middle of a rollback.
        run_root launchctl bootout "system/com.burrowee.@UNIT_DOT@gateway.guard" 2>/dev/null || true
        run_root launchctl bootstrap system "$_gp" || return 1
        ;;
    Linux)
        run_root systemd-run --unit=burrowee-@UNIT_DASH@gateway-guard --collect \
            "$_guard" "$TXN_DIR" || return 1
        ;;
    *)
        # A DELIBERATE REFUSAL, not a warning-and-continue.
        #
        # The choice is real, so it is stated: this host has neither launchd
        # nor systemd, so nothing on it can hold the guard outside the
        # operator's session — and this script's fresh path no longer restarts
        # anything itself (load_units left the foreground with Task 7). Warning
        # and continuing would place binaries, write phase=handoff to a guard
        # that does not exist, time out in reattach, and exit 0 having
        # restarted nothing: the exact false-green I6 describes, made
        # unconditional. Refusing costs an unsupported platform its install and
        # says why; continuing costs it the truth about what happened.
        echo "error: no launchd and no systemd on $(uname -s) — there is nothing on this host" >&2
        echo "error: that can supervise the install guard, and an unguarded restart is the" >&2
        echo "error: failure this installer exists to prevent." >&2
        echo "hint: nothing has been written yet; the running install is untouched." >&2
        return 1
        ;;
    esac

    # Three outcomes, three states — see GUARD_ARMED's own declaration. `|| _gpa=$?`
    # and not a bare call: this script runs under `set -e`, so guard_prove_armed's
    # deliberate non-zero "unproven" return would abort the install here.
    _gpa=0
    guard_prove_armed || _gpa=$?
    case "$_gpa" in
    0)
        GUARD_ARMED=1
        echo "guard armed — transaction $TXN_DIR"
        ;;
    2)
        GUARD_ARMED=unproven
        echo "guard handed to the supervisor, unproven — transaction $TXN_DIR"
        ;;
    *)
        return 1
        ;;
    esac
}

# ---------------------------------------------------------------------------
# guard_refuse_concurrent — refuse to arm on top of a guard that is still
# working.
#
# guard.pid was written from the first day with the comment "so a second
# install can refuse to race a live guard", and nothing read it. Worse, the
# Darwin arm unconditionally boots the guard LABEL out, so a second install
# starting while the first guard was mid-rollback killed it between restoring
# files and restarting the daemon — manufacturing the stranding this whole
# design removes.
#
# The check is per TRANSACTION, and a transaction only counts when BOTH its
# pid is alive AND its phase is non-terminal: a finished guard's pid file
# outlives it, and a recycled pid must not refuse an install forever. This
# run's own transaction cannot match — txn_begin has just created it and the
# guard has not been armed, so it carries no guard.pid at all.
# ---------------------------------------------------------------------------
guard_refuse_concurrent() {
    _grc_base="$SYS_DATA_DIR/install"
    [ -d "$_grc_base" ] || return 0
    # txn_list_dir / txn_read_file, never a bare glob and a bare cat: the
    # transaction tree is root-owned 0700 (see the helpers above), so an
    # unprivileged installer's glob would find nothing and this check would
    # silently never refuse anything.
    for _grc_stamp in $(txn_list_dir "$_grc_base"); do
        _grc_t="$_grc_base/$_grc_stamp"
        _grc_pid="$(txn_read_file "$_grc_t/guard.pid")"
        case "$_grc_pid" in '' | *[!0-9]*) continue ;; esac
        [ "$_grc_pid" != 0 ] || continue
        kill -0 "$_grc_pid" 2>/dev/null || continue
        _grc_phase="$(txn_read_file "$_grc_t/phase")"
        case "$_grc_phase" in
            ok | rolled-back | aborted | failed) continue ;;
        esac
        echo "error: a guard from an earlier install is still running (pid $_grc_pid," >&2
        echo "error: transaction $_grc_t, phase ${_grc_phase:-unknown})." >&2

        echo "error: arming a second guard would boot that one out — possibly between its" >&2
        echo "error: restore and the restart that finishes it — so this install refuses." >&2
        echo "hint: watch it finish with '@DISPATCHER@ gateway service guard-status', then re-run." >&2
        return 1
    done
    return 0
}

# guard_armed_marker_present — either of the two artefacts guard.sh writes as
# its first two statements, read through the elevated-read helpers because the
# transaction directory is root-owned 0700.
guard_armed_marker_present() {
    txn_file_exists "$TXN_DIR/guard.pid" && return 0
    txn_file_exists "$TXN_DIR/guard.log"
}

# ---------------------------------------------------------------------------
# GUARD_ARM_CEILING / GUARD_ARM_INTERVAL — how long guard_arm waits for the
# guard to prove it is actually RUNNING. Same unpublished test-seam shape as
# WAIT_CEILING/WAIT_INTERVAL: deliberately not BURROWEE_*, because those are
# the knobs the outer bootstrap forwards across its sudo boundary and these
# are not published to anyone.
# ---------------------------------------------------------------------------
GUARD_ARM_CEILING="${GUARD_ARM_CEILING:-10}"
GUARD_ARM_INTERVAL="${GUARD_ARM_INTERVAL:-1}"
[ "$GUARD_ARM_INTERVAL" -gt 0 ] 2>/dev/null || GUARD_ARM_INTERVAL=1

# ---------------------------------------------------------------------------
# guard_prove_armed — LOADED IS NOT RUNNING.
#
# `launchctl bootstrap` exiting 0 means launchd accepted the job; `systemd-run`
# exiting 0 means systemd accepted the transient unit. Neither says the process
# execed, and a guard that dies immediately (a broken interpreter line, a
# missing $TXN_DIR, an exec-format error) leaves an install that runs Phases
# 1-4, writes phase=handoff to nobody, times out in reattach printing "it is
# still running and will finish" — which is false — and exits 0. New binaries
# on disk, old daemon running, success reported.
#
# guard.sh's first two statements are `printf $$ > guard.pid` and
# `log "guard armed"`, in that order and before anything that can fail, so
# either artefact appearing is proof it reached its own body. Polled rather
# than assumed, and a failure here aborts before Phase 1 writes anything.
#
# BUT "I SAW NOTHING" IS NOT ALWAYS "THERE IS NOTHING". Both markers are read
# through txn_file_exists, which degrades to `sudo -n` because the transaction
# is root-owned 0700 and this script is routinely entered unprivileged. On a
# host configured with `Defaults timestamp_timeout=0` (or any sudoers that
# refuses a non-interactive re-auth) that `sudo -n` fails for every read, so a
# perfectly healthy guard is invisible — and the refusal below then blocks an
# install that worked on that same host before this check existed.
#
# The discriminator is a file that CERTAINLY exists: txn_begin wrote
# installer.pid into the same directory, with the same owner and the same mode,
# moments ago. If that cannot be seen either, the reads are blind and the guard
# has not been proven either way. Warn and continue there rather than refuse —
# a blind read is not evidence of a dead guard, and turning an unprovable state
# into a refusal costs the operator the install for a fact nobody established.
# When installer.pid IS readable and neither guard marker appeared, the reads
# work and the guard really did not start: that is the refusal, unchanged.
#
# THE BLIND PATH RETURNS 2, NOT 0, and that is the whole of what "fail open"
# means here. It used to return 0, which guard_arm read as proof and turned into
# GUARD_ARMED=1 — so on a host where the guard really had died, the install ran
# to the end announcing a guard that was not there, and a later abort_install
# deferred its entire undo to it: "the guard is undoing this install" printed
# over a host where nothing restored anything and nothing restarted. Continuing
# is still the right call (a blind read is not evidence of a dead guard, and
# refusing costs the operator an install for a fact nobody established); saying
# `1` about it was not. 2 means CONTINUE, UNPROVEN.
# ---------------------------------------------------------------------------
guard_prove_armed() {
    _gpa_waited=0
    while [ "$_gpa_waited" -lt "$GUARD_ARM_CEILING" ]; do
        if guard_armed_marker_present; then
            return 0
        fi
        sleep "$GUARD_ARM_INTERVAL"
        _gpa_waited=$((_gpa_waited + GUARD_ARM_INTERVAL))
    done
    if ! txn_file_exists "$TXN_DIR/installer.pid"; then
        echo "warning: neither $TXN_DIR/guard.pid nor $TXN_DIR/guard.log appeared within" >&2
        echo "warning: ${GUARD_ARM_CEILING}s — and neither did $TXN_DIR/installer.pid, which" >&2
        echo "warning: this script wrote itself when the transaction opened." >&2
        echo "warning: so the transaction cannot be READ from this shell, which is not the" >&2
        echo "warning: same as the guard not having started: the directory is root-owned 0700" >&2
        echo "warning: and every fallback read here is 'sudo -n', which this host refuses (a" >&2
        echo "warning: sudoers with timestamp_timeout=0, say)." >&2
        echo "warning: continuing rather than refusing an install over a fact that could not" >&2
        echo "warning: be established. The guard, if it started, is still watching." >&2
        echo "hint: run the install as root (or with a warm sudo timestamp) to get the" >&2
        echo "hint: arm-proof back; watch the outcome with '@DISPATCHER@ gateway service" >&2
        echo "hint: guard-status' either way." >&2
        # 2, never 0: continue, but do not let anything downstream claim a guard
        # is watching. See this function's header and GUARD_ARMED's declaration.
        return 2
    fi
    echo "error: the install guard was handed to the supervisor, which accepted it, but the" >&2
    echo "error: guard never started: neither $TXN_DIR/guard.pid nor $TXN_DIR/guard.log" >&2
    echo "error: appeared within ${GUARD_ARM_CEILING}s." >&2

    echo "error: a job that is LOADED but not RUNNING would let this install place binaries," >&2
    echo "error: hand the restart to nobody, and report success — so it refuses instead." >&2
    echo "hint: nothing has been written yet; the running install is untouched." >&2
    echo "hint: see $TXN_DIR/guard.err for what the supervisor captured." >&2
    return 1
}

# ---------------------------------------------------------------------------
# $BIN_DIR placement: one elevation decision, all-or-nothing.
#
# Mirrors gateway/update.sh's PLACE_ELEVATED (see that script's header for the
# full field history). $BIN_DIR was always writable under the old default
# ($HOME/.local/bin); it is root-owned under the new one
# (@ROOT@/bin), so placing straight onto the final names with a
# bare `install` would die on the first binary for anyone who is not already
# root. The elevation is decided ONCE per mode, by a real create rather than
# assumed — a run already at uid 0 never pays for a sudo call it does not need
# — and every write of one placement goes through the SAME decision, so a set
# can never end up half-elevated.
# ---------------------------------------------------------------------------
BIN_PLACE_ELEVATED=0

# bin_place_writable DIR — whether THIS process can create a file in DIR. A
# real create, not `[ -w ]`: the mode bits say yes for root on a read-only
# mount and cannot see an ACL, and the whole decision below rests on this
# answer.
bin_place_writable() {
    _bpw="$1/.burrowee-install-probe.$$"
    if (umask 077; : >"$_bpw") 2>/dev/null; then
        rm -f "$_bpw"
        return 0
    fi
    return 1
}

# decide_bin_place_elevated — the real-create probe, once. $BIN_DIR exists by
# the time this is asked — ensure_system_tree created it AS ROOT ahead of the
# first write of every mode — and it must not be created here: an unprivileged
# `mkdir -p` succeeding on a host whose /usr/local the invoking user owns is
# exactly how the exec surface would come to be owned by that user.
decide_bin_place_elevated() {
    if bin_place_writable "$BIN_DIR"; then
        BIN_PLACE_ELEVATED=0
    else
        BIN_PLACE_ELEVATED=1
    fi
}

# bin_place_run CMD… — run CMD directly, or through run_root when $BIN_DIR was
# found to need root. One decision applied to every write of the placement.
bin_place_run() {
    if [ "$BIN_PLACE_ELEVATED" = 1 ]; then
        run_root "$@"
    else
        "$@"
    fi
}

# bin_place_bin SRC DST — install a 0755 binary and strip the macOS quarantine
# xattr, through the elevation decided for $BIN_DIR.
bin_place_bin() {
    bin_place_run install -m 0755 "$1" "$2" || return 1
    if [ "$(uname -s)" = "Darwin" ]; then
        bin_place_run xattr -d com.apple.quarantine "$2" >/dev/null 2>&1 || true
    fi
    return 0
}

# bin_place_cleanup removes the staging directory, through the same elevation
# that created it. Idempotent: called on every failure path and on success.
BIN_STAGE_DIR=""
bin_place_cleanup() {
    [ -n "$BIN_STAGE_DIR" ] || return 0
    bin_place_run rm -rf "$BIN_STAGE_DIR" >/dev/null 2>&1 || true
    BIN_STAGE_DIR=""
}

# place_all_bins — stage every name in $BINS into $BIN_DIR/.burrowee-install.$$
# and rename each into place only once ALL are staged, through the elevation
# decided above. ALL SIX OR NONE: a refusal partway must not leave some new
# binaries beside some old ones — or, on a fresh host, some binaries present
# and some missing, which the unit-writing steps right after this would then
# treat as a complete install. Exits 1 with guidance on the first write that
# cannot proceed; before that point nothing in $BIN_DIR has been touched.
place_all_bins() {
    for b in $BINS; do
        [ -f "./$b" ] || { echo "missing $b in archive" >&2; exit 1; }
    done
    decide_bin_place_elevated
    BIN_STAGE_DIR="$BIN_DIR/.burrowee-install.$$"
    if ! bin_place_run mkdir -p "$BIN_STAGE_DIR"; then
        BIN_STAGE_DIR=""
        echo "install: cannot write $BIN_DIR — no binary was placed." >&2
        echo "install: the gateway installs there and nowhere else; re-run as root, or grant" >&2
        echo "install: this user sudo." >&2
        exit 1
    fi
    for b in $BINS; do
        if ! bin_place_bin "./$b" "$BIN_STAGE_DIR/$b"; then
            echo "install: could not stage $b for $BIN_DIR — NOT placing any binary." >&2
            bin_place_cleanup
            exit 1
        fi
    done
    for b in $BINS; do
        if ! bin_place_run mv -f "$BIN_STAGE_DIR/$b" "$BIN_DIR/$b"; then
            echo "install: could not move $b into $BIN_DIR — the placement is incomplete." >&2
            echo "install: re-run the install; the staged copies have been discarded." >&2
            bin_place_cleanup
            exit 1
        fi
    done
    bin_place_cleanup
    echo "installed to $BIN_DIR: $BINS"
}

# ---------------------------------------------------------------------------
# Phase 2 — verify what was placed, BEFORE anything is restarted.
#
# This is the cheap failure. Nothing has been severed: the old daemon is still
# serving, the operator is still connected, and a restore here costs a copy.
# Everything after the handoff costs a connection.
# ---------------------------------------------------------------------------
verify_placement() {
    _rc=0
    # Same gate as verify_root_exec_surface, and for the same reason: ownership
    # can only be asserted where root was genuinely obtained. The sandboxed
    # installer harness's pass-through `sudo` stub makes every "root-owned"
    # file here owned by the test user, so asserting uid 0 in that harness
    # would refuse every test run for a reason that says nothing about a real
    # host. Skip once, ahead of the loop, rather than repeating the note per
    # binary.
    if ! have_real_root; then
        echo "note: this run never reached uid 0, so the ownership of $BIN_DIR" >&2
        echo "note: cannot be asserted — skipping the root-secure check." >&2
    fi
    for b in $BINS; do
        if [ ! -f "$BIN_DIR/$b" ]; then
            echo "verify: $BIN_DIR/$b is missing" >&2; _rc=1; continue
        fi
        if [ ! -x "$BIN_DIR/$b" ]; then
            echo "verify: $BIN_DIR/$b is not executable" >&2; _rc=1; continue
        fi
        # rc 1 and rc 2 SEPARATED, the same way verify_root_exec_surface
        # separates them and for the same reason its own comment gives: they
        # send an operator to completely different places. "not root-secure"
        # on a host whose tree is already root:root 755 — because this host's
        # `stat` speaks neither dialect and nothing could be read at all — is a
        # day spent re-checking permissions that were right the first time.
        # This check imitated that precedent without inheriting the split.
        #
        # rc 3 (the leaf is absent) cannot reach here: the `[ ! -f ]` arm above
        # has already reported and `continue`d on that. It falls into the same
        # arm as rc 1 so the case is total, and would say the same true thing.
        if have_real_root; then
            _vp_rc=0
            path_is_root_secure "$BIN_DIR/$b" || _vp_rc=$?
            if [ "$_vp_rc" = 2 ]; then
                echo "verify: could not read the owner and mode of $BIN_DIR/$b — this host's" >&2
                echo "verify: 'stat' answered neither the GNU form (stat -c '%u') nor the BSD" >&2
                echo "verify: form (stat -f '%u') with a plain number, so its ownership is not" >&2
                echo "verify: insecure, it is unknown. The permissions of $BIN_DIR are NOT" >&2
                echo "verify: implicated — reading them is." >&2
                _rc=1; continue
            elif [ "$_vp_rc" != 0 ]; then
                echo "verify: $BIN_DIR/$b is not root-owned and unwritable all the way to /" >&2
                _rc=1; continue
            fi
        fi
        # Against the archive copy this run placed it from — proving the mv
        # landed the bytes we staged, not that the file merely exists.
        if [ -f "./$b" ] && [ "$(sha256_of "./$b")" != "$(sha256_of "$BIN_DIR/$b")" ]; then
            echo "verify: $BIN_DIR/$b does not match the archive copy" >&2; _rc=1
        fi
    done
    return "$_rc"
}

# verify_units — the unit files parse, and the ExecStart they name exists.
# A unit that names a binary that is not there is the failure mode that looks
# like a clean install right up until the restart.
verify_units() {
    _rc=0
    case "$(uname -s)" in
    Darwin)
        for u in com.burrowee.@UNIT_DOT@gateway.plist com.burrowee.@UNIT_DOT@gateway.updater.plist; do
            _p="$LAUNCHD_DIR/$u"
            [ -f "$_p" ] || { echo "verify: $_p is missing" >&2; _rc=1; continue; }
            if command -v plutil >/dev/null 2>&1 && ! plutil -lint "$_p" >/dev/null 2>&1; then
                echo "verify: $_p is not a valid plist" >&2; _rc=1
            fi
        done
        ;;
    Linux)
        for u in burrowee-@UNIT_DASH@gateway.service burrowee-@UNIT_DASH@gateway-updater.service; do
            _p="$SYSTEMD_DIR/$u"
            [ -f "$_p" ] || { echo "verify: $_p is missing" >&2; _rc=1; continue; }
        done
        ;;
    esac
    [ -x "$BIN_DIR/burrowee-gateway" ] || {
        echo "verify: the serve unit's ExecStart target $BIN_DIR/burrowee-gateway is not executable" >&2
        _rc=1
    }
    return "$_rc"
}

# ---------------------------------------------------------------------------
# consent_to_sever <migration|restart> — tell the operator their connection is
# about to go, and why, before it goes.
#
# ASKED BEFORE THE STEP THAT SEVERS, and which step that is depends on the
# run: a run with a pending migration loses the session inside
# migrate_from_legacy, not at the restart — gateway's own migrations/run.sh
# stops the daemon to copy state at rest, a long way before render_units even
# runs. A gate asked after the connection is already gone is not a gate.
#
# BOTH CALL SITES ARE NOW WIRED. The migration one was not, and the reason
# recorded here was wrong twice over: it named the SHARED ladder's
# _shared/migrations/adopt_user_tree.sh, which gateway does not use at all
# (tools/payload.sh's takes_shared_ladder covers edge, cli and relay only —
# gateway's migrations/ is copied verbatim from the gateway repo), and it
# concluded that nothing could announce the stop early enough. Something can:
# the runner itself, asked. gateway's run.sh carries a read-only
# --probe-pending mode that walks the ladder and reports whether a rung is
# pending without touching anything, and should_ask_before_migration puts that
# question in front of migrate_from_legacy. Cross-repo, which is why it took a
# change on both sides rather than a hook this repo could add alone.
#
# NON-INTERACTIVE RUNS DO NOT PROMPT. Console pushes, CI and `curl … | sh`
# have no tty and today restart unconditionally; a blocking prompt would turn
# every automated install into a hang. BURROWEE_ASSUME_YES=1 is the explicit,
# scriptable override for an interactive host that wants the same behaviour
# (a supervised push run FROM a terminal, say).
#
# A DECLINE UNDOES THE INSTALL, not merely the restart — AND IT HANDS THAT
# UNDO TO THE GUARD, which is the whole correction here.
#
# This function used to do `snapshot_restore; txn_phase rolled-back; exit 1`
# itself, reasoning that marking the phase terminal first heads off a race
# with the guard, and that "nothing was restarted; the running gateway is
# undisturbed" is true of a daemon that was never touched.
#
# THE SECOND HALF IS FALSE ON EXACTLY THE RUN THIS DESIGN EXISTS FOR.
# migrate_from_legacy runs ~150 lines before this prompt, and gateway's own
# migrations/run.sh boots the serve label out of both domains to copy state at
# rest. From there until the guard's own restart the
# gateway is DOWN and, on Darwin, UNLOADED. snapshot_restore only copies files
# — it never restarts anything — so on a migrating host "declined, restored"
# left the daemon stopped, and `txn_phase rolled-back` then told the guard the
# transaction was already finished: its watch loop takes the "already
# terminal" branch and exits. That is the reported stranding through a
# different door. It is reached by an EOF read, too: on a migrating host the
# prompt below reads from a tty whose connection is already gone, EOF gives
# _ans='', and an empty answer is a decline.
#
# So the decline prints and EXITS. The guard's installer-died branch is what
# restores, restarts and VERIFIES — the three things a rollback is, of which
# the foreground could only ever do the first. The race the old comment was
# avoiding is not a race: the guard's rollback is the correct outcome, and it
# arrives within one poll (~1s). And on a host whose daemon was never stopped
# the guard does not bounce it either — rollback() skips the restart when the
# daemon is already serving the snapshot's version and the unit body is
# unchanged, which is precisely the "undisturbed" case this used to claim by
# assertion and now establishes by observation.
#
# THE CLOSING ADVICE IS PER CAUSE, AND IT HAS TO BE.
# "you do not need to stay connected" is true at the RESTART: `txn_phase
# handoff` has already been written by then, so the installer's work is
# finished and the guard CARRIES THE INSTALL THROUGH — restart, verify, and
# roll back only if the new build does not come up. Staying connected adds
# nothing.
#
# At the MIGRATION the same sentence is the reverse of what happens, and it
# was being printed at the exact moment the operator decides. The stop is
# ~150 lines BEFORE the handoff, so a severed session kills the installer at
# phase `replacing`, and the guard's watch loop then takes its "installer pid
# … exited at phase '…' without handing off — rolling back" arm: it UNDOES
# the install rather than finishing it. So on a tunnelled host with a pending
# rung an interactive install cannot complete either way — accepting rolls
# back when the session drops, declining rolls back immediately — and the one
# useful thing this prompt can do is say so and name the shape that does
# work: re-run where nothing depends on this session surviving.
#
# Only the closing paragraph is split. The cause line, the transaction and
# guard-status lines and the y/N prompt are shared, and the restart arm's
# three lines are byte-for-byte what they have always been.

consent_to_sever() {
    _when="$1"
    if [ -n "${BURROWEE_ASSUME_YES:-}" ] || ! has_tty; then
        return 0
    fi
    case "$_when" in
    migration) _cause="a pending state migration is about to stop the gateway to copy its state at rest" ;;
    *)         _cause="the gateway is about to be restarted onto the newly installed build" ;;
    esac

    # PROBED IN A SUBSHELL, then opened for real — the same two-step the
    # setup-blob prompt below uses and for the same reason: dash treats a
    # FAILED `exec` redirection as fatal and exits the WHOLE SCRIPT, even
    # inside a construct that looks like it should only fail the construct.
    # has_tty above already proved a controlling terminal exists, but it
    # probes fd 0; this opens fd 3 read-write, and proving that specific open
    # safe in a subshell first is what keeps every /dev/tty open in this file
    # to the one idiom that cannot take the script down with it.
    if ! ( exec 3<>/dev/tty ) 2>/dev/null; then return 0; fi
    exec 3<>/dev/tty
    # The guard's deadline must not fire while an operator reads this prompt.
    heartbeat_start
    {
        printf '\n'
        printf 'This host is serving as a @DISPATCHER@ gateway, and this session reaches it\n'

        printf 'THROUGH that gateway — %s.\n' "$_cause"
        printf 'Continuing will drop this connection.\n\n'
        case "$_when" in
        migration)
            printf 'A guard is already armed with a full snapshot of the previous install, but\n'
            printf 'it CANNOT carry this install through from here. The stop above comes\n'
            printf 'BEFORE the installer hands off, so this session going takes the installer\n'
            printf 'with it — and the guard rolls an installer that died mid-install BACK.\n'
            printf 'Continuing leaves this host on the build it is running now, not the new\n'
            printf 'one. Declining leaves it there too, undisturbed.\n\n'
            printf 'To actually complete the install, re-run it where nothing depends on\n'
            printf 'this session surviving:\n\n'
            printf '  nohup <the installer> > /tmp/burrowee-install.log 2>&1 &\n'
            printf '  (or under tmux/screen, or push the update from the console)\n\n'
            ;;
        *)
            printf 'A guard is already armed with a full snapshot of the previous install. It\n'
            printf 'will restart the gateway, verify the new build comes up, and roll back to\n'
            printf 'the snapshot if it does not — you do not need to stay connected.\n\n'
            ;;
        esac
        printf '  transaction   %s\n' "$TXN_DIR"
        printf '  on reconnect  @DISPATCHER@ gateway service guard-status\n\n'
        printf 'Continue? [y/N] '
    } >&3 2>/dev/null || true
    _ans=''
    IFS= read -r _ans <&3 2>/dev/null || _ans=''
    heartbeat_stop
    exec 3>&- 2>/dev/null || true

    case "$_ans" in
        y | Y | yes | YES) return 0 ;;
    esac
    abort_install "declined"

}

# ---------------------------------------------------------------------------
# abort_install <why> — the ONE way this script gives up once a transaction is
# open. There are two shapes, and which one applies is decided by whether a
# guard is actually watching.
#
# GUARD ARMED (the default path): print, and exit. Do NOT restore, and do NOT
# write a terminal phase. Both belong to the guard, and doing either here is
# what made the three foreground abort paths — a declined consent, a failed
# verify_placement, a failed verify_units — able to strand a host:
# `snapshot_restore` copies files and nothing else, and `txn_phase rolled-back`
# is terminal, so the guard was handed a finished transaction and did nothing.
# On a run whose migration had already stopped (and on Darwin unloaded) the
# daemon, that left it down with the only thing that could bring it back told
# not to. The guard's rollback() restores AND restarts AND verifies, it is
# running detached with the snapshot already in hand, and its installer-died
# branch fires within one poll of this process exiting.
#
# NO GUARD ARMED (BURROWEE_NO_RESTART): nothing this run was ever going to
# restart anything, and no guard exists to hand the undo to — so the
# foreground restore IS the whole undo, and marking the phase terminal records
# it for guard-status.
#
# GUARD UNPROVEN: the third state, and the reason GUARD_ARMED is not a boolean.
# The supervisor accepted the guard and guard_prove_armed could not READ the
# transaction to tell whether it started (a root-owned 0700 tree, and a host
# whose sudoers refuses every `sudo -n`). Deferring the whole undo to a guard
# that may not exist is how this branch used to strand such a host: it printed
# "the guard is undoing this install" and did nothing, and nothing else ever
# did anything either. So this arm takes the halves that are safe under BOTH
# possibilities:
#
#   * it RESTORES in the foreground. If the guard is dead this is the only undo
#     there is; if it is alive the guard restores the same files from the same
#     snapshot moments later, and a file copied twice is a file copied.
#   * it writes NO terminal phase. `rolled-back`/`aborted` are terminal, and a
#     live guard reading a terminal phase takes its "already terminal" arm and
#     stops — which would trade a possible stranding for a certain one, since
#     only the guard can RESTART. Leaving the phase alone lets the guard reach
#     its own verdict if it is there, and leaves guard-status showing a
#     transaction that never finished if it is not, which is the truth.
#   * it says both possibilities out loud, and gives the operator the one
#     command that distinguishes them.
#
# AND IT WRITES THE PHASE THE SNAPSHOT ACTUALLY SUPPORTS. This branch used to
# write `rolled-back` unconditionally, which guard-status renders as "the new
# build did not come up — the previous one was restored and is serving". On a
# VIRGIN host — no gateway ever installed, `BURROWEE_NO_RESTART=1`, a failed
# verify_placement or verify_units — the snapshot is the empty shell
# snapshot_take leaves behind, snapshot_restore copies nothing, and that
# sentence names a build that never existed. `aborted` is the phase for
# exactly that host ("there was no previous install to restore, so nothing was
# started"), and it is true here in both halves: this mode restarted nothing by
# construction.
#
# Prose only, and knowingly so: nothing is started on this path either way, so
# the phase file is the whole of what changes. But the phase file is what
# guard-status reports to an operator, and it is the only record this mode
# leaves.
#
# AND IT NEVER ASSERTS A HOST FACT IT DID NOT OBSERVE. The predicate is
# snapshot_binaries_state, which has three answers and not two: this script is
# routinely entered by an unprivileged shell and the transaction is root-owned
# 0700, so "the snapshot holds no binaries" and "this shell cannot read the
# snapshot" are both reachable — and the old two-valued predicate collapsed
# them, printing "this host had no previous gateway install" out of blindness.
# On `unknown` this branch says exactly what it saw, restores nothing (there is
# nothing it could read to restore) and — the important half — writes NO
# terminal phase. `aborted` there would record "there was no previous install"
# as a finding, in the one direction that costs something: an operator who has
# one, and now believes this run established they do not. A transaction left
# un-finalised reads as unfinished, which is what it is.
#
# The exit status is 1 on every arm: an aborted install failed.
# ---------------------------------------------------------------------------
abort_install() {
    if [ "$GUARD_ARMED" = 1 ]; then
        echo "install: $1 — the guard is undoing this install." >&2
        echo "install: it restores the previous binaries, units, config and state, and makes" >&2
        echo "install: sure the gateway is serving again before it stops." >&2
        echo "install: transaction $TXN_DIR" >&2
        echo "install: check the outcome with: @DISPATCHER@ gateway service guard-status" >&2
        exit 1
    fi
    if [ "$GUARD_ARMED" = unproven ]; then
        echo "install: $1 — a guard was handed to the supervisor, but this shell could not" >&2
        echo "install: read the transaction to prove it started, so it may or may not be" >&2
        echo "install: watching." >&2
        echo "install: restoring the previous install here anyway: if the guard is dead this" >&2
        echo "install: is the only undo there is, and if it is alive it restores the same" >&2
        echo "install: files from the same snapshot." >&2
        snapshot_restore || echo "install: the restore itself reported errors — see above" >&2
        echo "install: the transaction is deliberately NOT marked finished — a live guard" >&2
        echo "install: reading a terminal phase would stop without restarting anything, and" >&2
        echo "install: restarting is the half this shell cannot do." >&2
        echo "install: transaction $TXN_DIR" >&2
        echo "install: check whether the guard reported: @DISPATCHER@ gateway service guard-status" >&2
        echo "install: if it never does, start the gateway by hand: sudo @DISPATCHER@ gateway service install" >&2
        exit 1
    fi
    case "$(snapshot_binaries_state "$TXN_DIR/snapshot")" in
    some)
        echo "install: $1 — restoring the previous install." >&2
        echo "install: no guard was armed this run (BURROWEE_NO_RESTART), and nothing was" >&2
        echo "install: restarted, so the running gateway is the one this restores." >&2
        snapshot_restore || echo "install: the restore itself reported errors — see above" >&2
        txn_phase rolled-back
        exit 1
        ;;
    none)
        echo "install: $1 — there is nothing to restore." >&2
        echo "install: this host had no previous gateway install, and no guard was armed this" >&2
        echo "install: run (BURROWEE_NO_RESTART), so nothing was started and nothing was undone." >&2
        echo "install: the host is as it was found, apart from the files this run placed." >&2
        txn_phase aborted
        exit 1
        ;;
    esac
    # unknown — and the message says what was OBSERVED, not what is true of the
    # host. The transaction is root-owned 0700, this shell is not root, and its
    # `sudo -n` fallback was refused, so nothing at all could be read out of it:
    # a previous install may be sitting in that snapshot unrestored.
    echo "install: $1 — and this shell cannot read the transaction, so whether there is a" >&2
    echo "install: previous install to restore could not be established." >&2
    echo "install: $TXN_DIR is root-owned and 0700; this install is running unprivileged and" >&2
    echo "install: its non-interactive elevation ('sudo -n') was refused, which is what a" >&2
    echo "install: sudoers with timestamp_timeout=0 does to every read here." >&2
    echo "install: nothing was started (BURROWEE_NO_RESTART) and nothing was restored." >&2
    echo "install: the transaction is deliberately left unfinished rather than recorded as" >&2
    echo "install: 'nothing to restore', which this run did not observe." >&2
    echo "install: inspect it as root: sudo ls -l $TXN_DIR/snapshot/bin" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# REATTACH_CEILING / REATTACH_INTERVAL — how long reattach (below) polls the
# transaction's phase file for the guard's verdict before giving up on
# watching it. Same test-seam shape as WAIT_CEILING/WAIT_INTERVAL above, and
# for the same reason: production wants minutes (a migration copying a large
# store, or a slow supervisor, can take a while), a suite that never runs a
# real guard wants zero.
# ---------------------------------------------------------------------------
REATTACH_CEILING="${REATTACH_CEILING:-180}"
REATTACH_INTERVAL="${REATTACH_INTERVAL:-2}"
# A floor of 1, for the same reason guard.sh floors GUARD_VERIFY_INTERVAL: the
# loop below advances $_waited by exactly this value, so at 0 the counter never
# moves and the ceiling is never reached — an infinite `sleep 0` spin, not a
# fast poll. The seam is for a suite that wants a SHORT interval, and 1 is the
# shortest one that terminates.
[ "$REATTACH_INTERVAL" -gt 0 ] 2>/dev/null || REATTACH_INTERVAL=1

# ---------------------------------------------------------------------------
# reattach — follow the guard to its verdict.
#
# DYING HERE IS HARMLESS. The guard is a child of launchd/systemd (guard_arm),
# not of this shell, and it decides the outcome whether or not this process,
# this shell, or the operator's own connection is still around to watch —
# reattach is a convenience for the case they are, never a dependency for the
# case they are not.
# ---------------------------------------------------------------------------
reattach() {
    _waited=0
    while [ "$_waited" -lt "$REATTACH_CEILING" ]; do
        # txn_read_phase, not a bare `cat`: the transaction directory is
        # root-owned 0700 and this script is routinely run by an unprivileged
        # shell that elevates per command, so a plain read returns "" for a
        # phase file that plainly exists — and "" falls through every arm below
        # to the give-up path, reporting "the guard has not reported yet" about
        # a guard that reported minutes ago.
        _p="$(txn_read_phase)"
        [ -n "$_p" ] || _p=unknown
        case "$_p" in

        ok)
            echo "install: the gateway is serving the new build"
            return 0 ;;
        rolled-back)
            echo "install: the new build did not come up — the previous one was restored" >&2
            echo "install: and is serving. Details: @DISPATCHER@ gateway service guard-status" >&2
            return 1 ;;
        aborted)
            # NOT folded into `rolled-back`, although both return 1. The guard
            # writes this phase only when the snapshot held no previous install
            # to restore — a fresh host, or one whose gateway was never there —
            # so telling the operator "the previous one was restored and is
            # serving" would name a build that does not exist and a daemon that
            # is not running. The host is as it was found, and that is the one
            # thing this line has to say.
            echo "install: the install was aborted and nothing was started — this host had no" >&2
            echo "install: previous gateway to restore, so no gateway is running." >&2
            echo "install: Details: @DISPATCHER@ gateway service guard-status" >&2
            return 1 ;;
        failed)
            # NOT "the rollback did not come up either". Two guard paths write
            # `failed`, and only one of them rolled anything back: the other is
            # a host with no previous install to restore, whose new build was
            # started and never reported its version. This line is read by an
            # operator who may be on either, so it says the half that is true of
            # both and leaves the which-door to the guard log guard-status
            # prints. Same sentence the cli's own guardPhaseSummary renders —
            # the two are kept in step on purpose.
            echo "install: the host is not serving and the guard could not get it serving —" >&2
            echo "install: this needs hands." >&2
            echo "install: @DISPATCHER@ gateway service guard-status $TXN_STAMP" >&2
            return 2 ;;
        esac
        sleep "$REATTACH_INTERVAL"
        _waited=$((_waited + REATTACH_INTERVAL))
    done
    echo "install: the guard has not reported yet; it is still running and will finish"
    echo "install: without this session. @DISPATCHER@ gateway service guard-status"
    return 0
}

# ---------------------------------------------------------------------------
# Mode dispatch.
# ---------------------------------------------------------------------------

# Sourced by the test suites to reach the helpers above without performing an
# install. It is checked here, at the TOP of the mode dispatch, so no mode can
# be entered by a sourcing caller.
if [ -n "${BURROWEE_SOURCE_ONLY:-}" ]; then
    return 0 2>/dev/null || exit 0
fi

if [ -n "${BURROWEE_UNITS_ONLY:-}" ]; then
    # ------------------------------------------------------------------
    # `@DISPATCHER@ gateway service install` and `doctor --fix`, both of which
    # reach here through installGatewayUnits (gateway's
    # cmd/burrowee-gateway-cli/service.go). Both are OPERATOR verbs, typed in
    # an operator's session — and on a gateway that session is routinely
    # tunnelled THROUGH the daemon this mode stops and starts.
    #
    # SO THIS MODE IS GUARDED, exactly like the fresh-install path below, and
    # for exactly the same two sever points:
    #
    #   migrate_from_legacy   gateway's own migrations/run.sh stops (and on
    #                         Darwin unloads) the daemon to copy state at rest
    #   the restart           which used to be load_units, right here, in this
    #                         script's own foreground
    #
    # It had BOTH and neither was protected: an operator running `service
    # install` over their own tunnel lost the shell at whichever came first,
    # and everything after it — the version anchor above all — silently never
    # ran, on a host whose daemon was already down.
    #
    # ONE GUARD, THE SAME ONE. txn_begin / snapshot_take / guard_arm here are
    # the same three calls the fresh path makes, handing the same guard.sh to
    # the same supervisor; there is no second implementation and no
    # units-only variant of it. What differs is stated at each of the two
    # points below where it actually differs.
    # ------------------------------------------------------------------

    # First, ahead of the consent prompt and every write: this mode places no
    # binaries at all, so the cli the runner will probe is the one already on
    # disk. If it cannot migrate, render_units below would leave root-scheme
    # units on a host whose state never moved.
    assert_can_migrate "$(migrate_cli_path)"
    # AHEAD OF txn_begin, and deliberately not moved down beside the fresh
    # path's own call. Both of these are read-and-refuse: they inspect the
    # unit already on disk and either return or exit, writing nothing. Run
    # before the transaction exists, a refusal costs a snapshot that was never
    # taken and a guard that was never armed. Run after, the same refusal
    # exits the installer at phase `replacing`, and the guard's installer-died
    # branch then "rolls back" a host on which nothing was ever done. The
    # fresh path has no choice — it has already placed binaries by the time it
    # asks — and this one does.
    check_service_override

    # ---- Phase 0: snapshot + arm --------------------------------------
    # BEFORE remove_legacy_user_units, which is this mode's first write, and a
    # long way before migrate_from_legacy, which is its first STOP. Arming
    # after either would leave the guard blind to the sever point that
    # actually fires first on a migrating host.
    txn_begin
    snapshot_take
    guard_arm

    # ---- Phase 1: replace ---------------------------------------------
    # `replacing` and not a new token: the phase file is a state machine
    # shared with guard.sh and with the cli's guardPhaseSummary, and what this
    # phase means there is "writes are in flight and the snapshot can undo
    # them", which is exactly true here. That this mode's writes are units and
    # migrated state rather than binaries is not a distinction anything
    # downstream acts on.
    txn_phase replacing

@STABLE_ONLY_BEGIN@
    remove_legacy_user_units
@STABLE_ONLY_END@
    # The migration's own consent gate, asked BEFORE the stop and not at the
    # restart — the same reasoning, and the same call, as the fresh path's:
    # on a host with a pending rung the runner stops the daemon and takes a
    # tunnelled operator's session with it, so a prompt read afterwards is
    # read from a terminal that no longer exists. Silent when nothing is
    # pending, never asked at all with no tty (should_ask_before_migration).
@STABLE_ONLY_BEGIN@
    if should_ask_before_migration; then
        consent_to_sever migration
    fi
    # Before render_units. A migration that fails for ANY reason exits this
    # script — and a root-scheme unit left on disk by a run that then aborted
    # is bootstrapped by launchd at the next reboot regardless, against a
    # config root the migration never populated.
    migrate_from_legacy
@STABLE_ONLY_END@
@BETA_ONLY_BEGIN@
    seed_beta_config
@BETA_ONLY_END@
    render_units

    # THE LINKS AND BOTH SWEEPS ARE NOT HERE ANY MORE. They used to follow a
    # synchronous load_units on this path; the restart is now handed to the
    # guard, and the guard runs them through the kept installer once it has
    # PROVEN the new build is serving (sweep_stale_bins_via_kept_installer).
    # That is the same ordering rule they always had — nothing may replace or
    # remove a path the loaded units still name — now keyed to the restart
    # that actually happened rather than to one this script performed.

    # ---- the state writes, ALL of them before the handoff --------------
    # These used to sit after load_units, which is to say after the sever
    # point — so an operator whose session died at the restart kept the newly
    # rendered root-scheme units and the migrated state, and kept an anchor
    # still naming the OLD release. record_installed_version is what the NEXT
    # run's migration gate reads, so a stale anchor there does not merely
    # mis-report this run: it feeds the wrong floor into every run after it.
    report_unrecorded_migration
    # The anchor, from the fourth and last entry point. Its absence here is a
    # large part of why the ledger is effectively unwritten in the field: the
    # runner falls back to a migration's own --applies probe only when NOTHING is
    # recorded, and with two of the four entry points never writing, that
    # exceptional path became the normal one on most hosts.
    #
    # Same guard as everywhere else: an unrecorded migration must not have its
    # version written, or the receipt-gated re-runnable rung becomes a
    # version-gated never-again one. And no version supplied still records
    # nothing — inventing one is worse than leaving it absent.
    if [ "$MIGRATE_UNRECORDED" = "0" ]; then
        record_installed_version "${BURROWEE_VERSION:-}"
    fi

    # ---- Phase 2: verify ----------------------------------------------
    #
    # verify_placement IS DELIBERATELY NOT CALLED HERE, and skipping it is not
    # a gap this mode tolerates — it is a check that has nothing to say about
    # this mode, in two independent ways:
    #
    #   * it walks $BINS, which includes `@DISPATCHER@` and `burrowee-register`.
    #     This mode places neither (nothing but ensure_root_exec_surface
    #     places anything at all here), so on a host that legitimately does
    #     not carry them it would fail an install that did nothing wrong.
    #   * its last and strongest check compares each placed binary's sha256
    #     against the archive copy `./$b`. There is no archive on this path —
    #     `service install` runs a kept installer with no bundle beside it —
    #     so that comparison is skipped by its own `[ -f "./$b" ]` guard and
    #     the "verify" would be a walk of files this run never touched.
    #
    # WHAT ACTUALLY PLACES ANYTHING HERE ALREADY VERIFIES ITSELF.
    # render_units calls ensure_root_exec_surface, which places $ROOT_BINS,
    # this script and guard.sh into $BIN_DIR and then ends in
    # verify_root_exec_surface — the root-owned, non-root-writable-to-/ walk
    # over every path a unit is about to name. It returns non-zero and
    # render_units aborts under `set -e` before a single unit is written. So
    # the placement this mode performs is proved by the function that performs
    # it, which is a stronger arrangement than a second pass over it here.
    #
    # verify_units DOES apply and IS called: units are genuinely rendered on
    # this path, and its own last check — that the serve unit's ExecStart
    # target is executable — is precisely the pairing between the unit just
    # written and the binary ensure_root_exec_surface just placed.
    echo "note: this mode places no binaries, so there is no bundle to verify a" >&2
    echo "note: placement against; the root-exec surface render_units did place was" >&2
    echo "note: proved by verify_root_exec_surface before any unit was written." >&2
    verify_units || abort_install "unit verification failed"

    txn_phase verified
    echo "verified: the units are in place and consistent"

    # ---- Phases 3-5: consent, handoff, reattach ------------------------
    #
    # THE RESTART IS NOT PERFORMED HERE. load_units used to be the statement
    # above this one, and it restarted the daemon in this shell's foreground —
    # the shell reading its output over a tunnel through that very daemon. The
    # guard armed at Phase 0 owns it now: it holds the snapshot, it is a child
    # of launchd/systemd rather than of this session, and it can roll back if
    # the new build does not come up, which this shell cannot do once its own
    # connection is the thing that just dropped.
    #
    # sweep_stale_user_bins moved with it rather than staying here. It deletes
    # per-user binaries, and until the daemon has actually restarted onto the
    # loaded units a still-running per-user process may still name one — so it
    # must run AFTER a verified restart, which on this path means inside the
    # guard. guard.sh's do_restart runs it (sweep_stale_bins_via_kept_installer)
    # off the root-secure $BIN_DIR/install.sh, only on the verified-serving
    # branch. The updater start load_units used to perform moves the same way,
    # to the guard's advance_updater — which is why finish_with_updater_verdict
    # is gone from this mode's tail: there is no foreground updater start left
    # for it to report on, and reattach's verdict covers the whole install.
    #
    # `!= 0`, not `= 1`: GUARD_ARMED is also `unproven` (see its declaration).
    # Same reasoning as the fresh path's — a guard the supervisor accepted is
    # watching a deadline, and skipping the handoff would leave it to time out
    # and roll a healthy host back.
    _verdict=0
    if [ "$GUARD_ARMED" != 0 ]; then
        consent_to_sever restart

        # Printed BEFORE the handoff, never after: once the guard restarts the
        # gateway, this connection — tunnelled through the very daemon being
        # restarted — may already be gone, and a line printed into a dead
        # connection reaches no one.
        echo ""
        echo "handing the restart to the guard. If this connection drops, reconnect and run:"
        echo "    @DISPATCHER@ gateway service guard-status"
        echo ""
        txn_phase handoff

        # `|| _verdict=$?`, never a bare call: under `set -e` a reattach
        # returning 1 (rolled back) or 2 (the rollback failed) would abort
        # here instead of reaching the exit below with the verdict it just
        # computed.
        reattach || _verdict=$?
    else
        # BURROWEE_NO_RESTART, honoured here the same way the fresh path
        # honours it (guard_arm's own header): nothing was armed, so there is
        # nobody to consent to, nobody to hand off to and nobody to reattach
        # to. The units are rendered on disk and NOT loaded — loading them is
        # what starts them, since a Darwin `bootstrap` on a RunAtLoad plist
        # starts the daemon, which is the one thing this flag asks not to
        # happen.
        echo ""
        echo "units staged on disk. Nothing was restarted (BURROWEE_NO_RESTART)."
        echo "start the gateway when you are ready with:"
        echo "    sudo @DISPATCHER@ gateway service install"
        echo ""
    fi

    # NO DOCTOR TAIL, unlike the fresh path, and the reason is this mode's own
    # callers: `doctor --fix` reaches here through installGatewayUnits, so a
    # doctor call at the end of this block would be doctor running itself as
    # its own last remediation step. The fresh path has no such caller.

    # THE ADVICE BELONGS HERE, AND THIS MODE IS WHY IT CANNOT BE SKIPPED.
    #
    # This is the ONLY path on which the gateway's exec-root sweep runs: the
    # guard calls sweep_stale_exec_root through the kept installer
    # (guard.sh's sweep_stale_bins_via_kept_installer), and the guard is armed
    # from here. So the run that REMOVES /usr/local/bin/burrowee-gateway-cli
    # and the shared `@DISPATCHER@` dispatcher from a converging 0.2 host is
    # exactly this one — and until now it was the one run that printed no
    # replacement instruction. Worse, update mode ends by telling the operator
    # to run `sudo @DISPATCHER@ gateway service install`, which is this mode: the
    # sequence finished with their typed command gone and nothing said about
    # it anywhere.
    #
    # It corrects an earlier reading of mine that units-only "places no
    # binaries, so it is not an install". Placement was never the test. A path
    # that REMOVES the operator's command has to say how to reach the
    # replacement, whatever we call the mode.
    #
    # PRINTED HERE RATHER THAN BESIDE THE SWEEP, because the sweep runs inside
    # the guard, whose output goes to $TXN/guard.log and not to the operator's
    # terminal. This foreground is the session they typed the verb in, and it
    # is the only place they will read anything. The advice is true before the
    # sweep completes as well as after — $BIN_DIR is off PATH either way.
    #
    # ON SUCCESS ONLY, same as the fresh path: a non-zero verdict means the
    # guard rolled the host back, and advice about a tree this run reverted is
    # advice about an install that did not happen.
    if [ "$_verdict" = 0 ]; then
        print_path_advice
    fi

    # reattach's verdict, and nothing after it: 0 served / handed off
    # unreported, 1 rolled back or aborted with nothing started, 2 the
    # rollback itself failed.
    exit "$_verdict"
fi
if [ -n "${BURROWEE_UPDATE:-}" ]; then
    # ------------------------------------------------------------------
    # Update mode: per-binary sha256 change detection, transactional swap.
    #
    # NO INSTALL GUARD HERE, and that is a decision rather than an omission:
    # this mode restarts nothing (it ends at BURROWEE_CHANGED and leaves the
    # restart to the updater agent), it runs under a daemon with no operator
    # session to sever, and the updater it runs under is already the thing
    # that survives — a guard here would have to restart the process running
    # it. The full argument is in guard.sh's header ("WHICH INSTALL MODES ARM
    # A GUARD"); do not re-derive it, and do not add guard_arm below.
    # ------------------------------------------------------------------

    # Parse --version <ver> if present (does NOT gate the swap; sha256 does).
    _install_version=""
    while [ $# -gt 0 ]; do
        case "$1" in
        --version)
            shift
            if [ $# -gt 0 ]; then
                _install_version="$1"
                shift
            fi
            ;;
        *) shift ;;
        esac
    done
    # The outer bootstrap re-runs this script in update mode (the `--force` full
    # reinstall) with the resolved release tag in BURROWEE_VERSION and NO argv of
    # its own, so that path recorded no version at all. Argv wins where both are
    # present; record_installed_version normalises either shape.
    if [ -z "$_install_version" ]; then _install_version="${BURROWEE_VERSION:-}"; fi

    # Whose slot is it? Answered up front, because it decides both whether a
    # migration will be attempted at all (and so whether the pre-flight below
    # applies) and whether the version may be recorded at the end.
    _slot_owner="$(unit_owner "$(core_unit_path)")"
    _own_slot=0
    if [ -z "$_slot_owner" ] || [ "$_slot_owner" = "$SERVICE_USER" ]; then _own_slot=1; fi

    # The tree first, AS ROOT, before any probe looks at $BIN_DIR — see
    # ensure_system_tree. A failure here is before Phase 2 backs anything up.
    ensure_system_tree || exit 1

    # Decide elevation ONCE, before the first write — same rule place_all_bins
    # follows below, and update.sh's PLACE_ELEVATED: a real create, not an
    # assumption. Failing to even create $BIN_DIR is the FIRST write of this
    # mode, so it fails here, before Phase 2 backs anything up.
    decide_bin_place_elevated
    if [ "$BIN_PLACE_ELEVATED" = 1 ] && ! bin_place_run mkdir -p "$BIN_DIR"; then
        echo "update: cannot write $BIN_DIR — no binary was replaced." >&2
        echo "update: $BIN_DIR is root-owned; re-run as root, or grant this" >&2
        echo "update: user sudo." >&2
        exit 1
    fi

    # Phase 1: detect which binaries changed. BURROWEE_FORCE=1 (set by the Go
    # side only on `gateway update --force`) forces every serve binary to be
    # re-placed regardless of sha256 — a --force onto the already-installed
    # version has byte-identical binaries, so without this it would place
    # nothing and the operator's "reinstall completely" would be a no-op.
    #
    # burrowee-gateway-cli IS placed here, and that is a change from the shape
    # that shipped: the migration calls `burrowee-gateway-cli migrate`, and the
    # runner probes the INSTALLED cli for the verb. Leaving a 0.1.115 cli on
    # disk while swapping everything around it guaranteed that probe would fail
    # — with the units already written. gateway/update.sh, the other half of the
    # same update, has always carried the cli in its BINS; the two paths now
    # agree. Only burrowee-gateway-updater stays excluded: it is on its own
    # track, and replacing the binary a running updater is executing from
    # mid-update is what that exclusion exists to prevent.
    CHANGED=""
    for b in $BINS; do
        [ "$b" = "burrowee-gateway-updater" ] && continue   # its own update track: never replaced from inside an update it is running
        _staged="./$b"
        [ -f "$_staged" ] || { echo "missing $b in bundle" >&2; exit 1; }
        _staged_sum="$(sha256_of "$_staged")"
        _cur_sum=""
        if [ -f "$BIN_DIR/$b" ]; then
            _cur_sum="$(sha256_of "$BIN_DIR/$b")"
        fi
        if [ -n "${BURROWEE_FORCE:-}" ] || [ "$_staged_sum" != "$_cur_sum" ]; then
            CHANGED="${CHANGED:+$CHANGED }$b"
        fi
    done

    # Phase 1b — the pre-flight, deliberately between detection (which writes
    # nothing) and the first write. Phase 1 has already proved every staged
    # binary exists, so a refusal here is about the verb, not a missing file.
    #
    # Skipped when the slot belongs to another user: the branch below then
    # defers the migration entirely, so there is nothing to be unable to
    # complete, and refusing would block a binary swap that is independently
    # correct.
    if [ "$_own_slot" = "1" ]; then
        assert_can_migrate "./burrowee-gateway-cli"
    fi

    # Phase 2: transactional backup of all to-be-replaced binaries.
    _backed_up=""
    for b in $CHANGED; do
        if [ -f "$BIN_DIR/$b" ]; then
            bin_place_run cp "$BIN_DIR/$b" "$BIN_DIR/$b.bak-$$"
            _backed_up="${_backed_up:+$_backed_up }$b"
        fi
    done

    # Phase 3: place changed binaries; rollback on any failure.
    _placed=""
    for b in $CHANGED; do
        if bin_place_bin "./$b" "$BIN_DIR/$b"; then
            _placed="${_placed:+$_placed }$b"
        else
            # Restore all backups and abort.
            for _rb in $_backed_up; do
                if [ -f "$BIN_DIR/$_rb.bak-$$" ]; then
                    bin_place_run cp "$BIN_DIR/$_rb.bak-$$" "$BIN_DIR/$_rb" 2>/dev/null || true
                    bin_place_run rm -f "$BIN_DIR/$_rb.bak-$$"
                fi
            done
            echo "update: failed to install $b — rolled back" >&2
            exit 1
        fi
    done

    # Phase 4: remove backups on success.
    for b in $_backed_up; do
        bin_place_run rm -f "$BIN_DIR/$b.bak-$$"
    done

    # Migrate, THEN refresh the system unit FILES only — never load/restart them
    # here (the updater restarts the kernel out-of-band; loading would bootout the
    # very process running this script), never touch another user's slot, and
    # never fail the binary swap for lack of sudo: a unit refresh can always
    # happen later via '@DISPATCHER@ gateway service install'.
    #
    # The migration comes first because a failed one exits this script, and a
    # root-scheme unit already on disk is bootstrapped by launchd at the next
    # reboot whatever this run reported — against a config root the migration
    # never populated. Leaving the OLD units in place is strictly better: they
    # point at a tree that still holds the host's identity.
    if [ "$_own_slot" = "1" ]; then
        # Inside this branch, not beside it: a migration claims whose identity the
        # root daemon adopts, and on a slot belonging to someone else that claim
        # would be wrong in the one direction that cannot be undone — a
        # re-registered node under the wrong identity. Update mode has no consent
        # prompt to settle it (unlike the install paths, which run
        # check_service_override first), so it defers instead.
        #
        # ROOT_BIN_PLACE_EXCLUDE, before either call below: migrate_from_legacy
        # and render_units both reach ensure_root_exec_surface, which places
        # every name in $ROOT_BINS — and burrowee-gateway-updater is one of
        # them, but this mode's own binary placement above deliberately never
        # touches it (BINS' own exclusion). Without this it would still get
        # silently overwritten from the bundle here, one function past the
        # exclusion meant to stop exactly that.
        ROOT_BIN_PLACE_EXCLUDE="burrowee-gateway-updater"
@STABLE_ONLY_BEGIN@
        migrate_from_legacy
@STABLE_ONLY_END@
        render_units || echo "note: service units not refreshed (needs sudo) — run '@DISPATCHER@ gateway service install'" >&2
        # The exec-root sweep still has to wait until the loaded units name
        # $BIN_DIR: the units-only reinstall (`@DISPATCHER@ gateway service
        # install`) does it after load_units. This path arms no guard — the
        # updater restarts the service itself right after this script exits —
        # so there is no later step here to hand it to.
        echo "note: once the service has restarted onto the new units, 'sudo @DISPATCHER@ gateway service install' sweeps the 0.2 copies out of $LEGACY_BIN_DIR"

        # The version LAST, and only once everything above succeeded. Recording it
        # before the migration would mean a failed migration leaves the new version on
        # disk with the old layout still in place — after which every later run reads
        # "already up to date" and the host never migrates again. A failed migration
        # exits non-zero above, so reaching here means there is nothing pending.
        #
        # INSIDE this branch, for the same reason the migration is: the deferring
        # branch below leaves a legacy tree unmigrated, and the runner consults a
        # migration's own --applies probe only when NO version is recorded. Writing
        # the version there would hand the numeric gate sole authority over a rung
        # that never ran, permanently — a second, independent route to the node
        # re-registering under a fresh identity.
        if [ "$MIGRATE_UNRECORDED" = "0" ]; then
            record_installed_version "$_install_version"
        fi
    else
        echo "note: gateway system service belongs to user '$_slot_owner' — units not refreshed" >&2
        echo "note: not migrating either — '@DISPATCHER@ gateway service install' takes the slot over first" >&2
        echo "note: and the installed version is not recorded, so the migration stays pending" >&2
    fi

    # AFTER the migration, never before — and that ordering is the whole point.
    # keep_installer_copy mkdir -p's $GW_HOME, and the runner's "$GW_HOME does
    # not exist" guard is the only thing standing between `curl … | sudo sh` and
    # a silently mis-targeted migration under ROOT's $HOME. Creating the
    # directory the runner uses as its evidence, before the runner is allowed to
    # look at it, made that guard unreachable from every entry point on this
    # host: root's tree always existed by the time it was asked about.
    #
    # The copy still has to happen: `service install` re-runs $GW_HOME/install.sh
    # and resolves migrations/ beside whichever install.sh is executing, so a
    # stale copy is a stale unit-writer that also cannot migrate. It is simply
    # not urgent — nothing between the top of this mode and here reads it, and a
    # migration that fails exits the script, at which point leaving the PREVIOUS
    # installer in place is the same "old is better than half-new" choice the
    # unit ordering already makes.
    keep_installer_copy

    report_unrecorded_migration

    # This mode has no start step of its own; say so rather than leaving the
    # operator to find a stopped service.
    if [ "$MIGRATED" = "1" ]; then
        echo "note: a migration stopped the gateway — it starts again on the updater's restart," >&2
        echo "note: or run '@DISPATCHER@ gateway restart' now." >&2
    fi

    # Final change-set line (MUST be the last stdout line).
    printf 'BURROWEE_CHANGED=%s\n' "$CHANGED"
    exit 0
fi

if [ -n "${BURROWEE_UNINSTALL:-}" ]; then
    # $BIN_DIR is root-owned on a converged host, but an uninstall also runs on
    # hosts whose /usr/local this user happens to own — decide elevation once,
    # the same way every other placement in this script does, rather than
    # assuming either.
    _uninstall_failed=""
    if [ -d "$BIN_DIR" ]; then
        decide_bin_place_elevated
        # Everything but the dispatcher first: the `@DISPATCHER@` decision below
        # asks whether any OTHER component is still installed, and asking it
        # while this component's own binaries are still on disk would always
        # answer yes.
        for b in $BINS; do
            [ "$b" = @DISPATCHER@ ] && continue
            if [ -e "$BIN_DIR/$b" ] && ! bin_place_run rm -f "$BIN_DIR/$b"; then
                _uninstall_failed="${_uninstall_failed:+$_uninstall_failed }$b"
            fi
        done
        # The bare `@DISPATCHER@` dispatcher is SHARED with every co-installed
        # component (an edge or a relay on the same host), so it goes only when
        # nothing else of ours is left in $BIN_DIR. Same rule, same order, as
        # the edge uninstall — and what makes the "keep a live link" guard in
        # unlink_operator_bins reachable at all.
        if ls "$BIN_DIR"/burrowee-* >/dev/null 2>&1; then
            echo "kept $BIN_DIR/@DISPATCHER@ (dispatcher) — other @DISPATCHER@ components remain installed"
        elif [ -e "$BIN_DIR/@DISPATCHER@" ] && ! bin_place_run rm -f "$BIN_DIR/@DISPATCHER@"; then
            _uninstall_failed="${_uninstall_failed:+$_uninstall_failed }@DISPATCHER@"
        fi
        # This script's own kept copy + migrations/, placed here by
        # ensure_root_exec_surface (never by BINS) — an uninstall that leaves
        # them behind hands the next install a root-owned installer it never
        # re-verified.
        [ -e "$BIN_DIR/install.sh" ] && { bin_place_run rm -f "$BIN_DIR/install.sh" || _uninstall_failed="${_uninstall_failed:+$_uninstall_failed }install.sh"; }
        [ -d "$BIN_DIR/migrations" ] && { bin_place_run rm -rf "$BIN_DIR/migrations" || _uninstall_failed="${_uninstall_failed:+$_uninstall_failed }migrations"; }
        # The install guard, placed here by guard_arm / ensure_root_exec_surface
        # for the same reason install.sh itself is: launchd and systemd exec it
        # as ROOT. Leaving it behind hands the next install a root-owned script
        # nothing re-verified, on a host that no longer has a gateway.
        [ -e "$BIN_DIR/guard.sh" ] && { bin_place_run rm -f "$BIN_DIR/guard.sh" || _uninstall_failed="${_uninstall_failed:+$_uninstall_failed }guard.sh"; }
        [ -e "$BIN_DIR/.installed-version" ] && bin_place_run rm -f "$BIN_DIR/.installed-version"
    fi

    # The operator-typed links, and only the ones that still point into
    # $BIN_DIR (spec §6.1 rule 4). Before the binaries are reported gone so an
    # operator reading the line does not still have a dangling `@DISPATCHER@` on
    # PATH.
    unlink_operator_bins

    echo "removed from $BIN_DIR: $BINS"
    if [ -n "$_uninstall_failed" ]; then
        echo "note: could not remove from $BIN_DIR (needs root): $_uninstall_failed — remove by hand" >&2
    fi

    # A pre-existing /usr/local/libexec/burrowee/gateway tree, if this host has
    # one, is left in place — this script never wrote to it and does not clean
    # it up; that is an operator's call, by hand.
    #
    # STILL TRUE, and deliberately kept that way. The install guard was briefly
    # placed into a freshly created /usr/local/libexec/burrowee, which would
    # have made this comment false AND left a root-execed binary no uninstall
    # removed. It lives on the $BIN_DIR surface instead (guard_arm), and its
    # removal is the guard.sh line up with install.sh and migrations/ above.

    # Remove the system service units (root) plus any legacy per-user units.
    # All best-effort: a missing unit or unavailable sudo must not stop uninstall.
    case "$(uname -s)" in
    Darwin)
        # The guard label is in this list, and it has to be: its plist is
        # RunAtLoad, so one left behind re-execs the guard against a stale
        # transaction directory at every boot — on a host that no longer has a
        # gateway at all. guard.sh removes it itself on every exit path
        # (remove_guard_unit); this is the belt to that braces, for a guard
        # that was SIGKILLed or a host whose /Library/LaunchDaemons was not
        # writable when it tried.
        for _label in com.burrowee.@UNIT_DOT@gateway com.burrowee.@UNIT_DOT@gateway.updater com.burrowee.@UNIT_DOT@gateway.guard; do
            if [ -f "$LAUNCHD_DIR/$_label.plist" ]; then
                run_root launchctl bootout "system/$_label" 2>/dev/null || true
                run_root rm -f "$LAUNCHD_DIR/$_label.plist" || true
            fi
        done
        ;;

    Linux)
        _removed=""
        for _unit in burrowee-@UNIT_DASH@gateway.service burrowee-@UNIT_DASH@gateway-updater.service; do
            if [ -f "$SYSTEMD_DIR/$_unit" ]; then
                run_root systemctl disable --now "$_unit" 2>/dev/null || true
                run_root rm -f "$SYSTEMD_DIR/$_unit" || true
                _removed=1
            fi
        done
        if [ -n "$_removed" ]; then
            run_root systemctl daemon-reload 2>/dev/null || true
        fi
        ;;
    esac
@STABLE_ONLY_BEGIN@
    remove_legacy_user_units
@STABLE_ONLY_END@

    exit 0
fi

# ---------------------------------------------------------------------------
# Fresh install (default mode).
# ---------------------------------------------------------------------------

# Before the first write, same invariant as update mode: this run places every
# binary including the cli, so the staged cli is the one the runner will probe.
# Owed only to a host that already has a gateway to migrate — see
# prior_install_present. A virgin host is still handed to the runner below:
# it is the authority on what (if anything) this host needs, and it declines
# an absent tree out loud by itself without ever calling the verb.
if prior_install_present; then
    assert_can_migrate "./burrowee-gateway-cli"
else
    echo "no gateway installed on this host — nothing to migrate, skipping the migration pre-flight"
fi

# Arm the guard BEFORE the first write, and before migrate_from_legacy — which
# stops the daemon itself (gateway's own migrations/run.sh) well before
# load_units ever restarts it, severing a tunnelled operator's session at the
# migration, not the restart. snapshot_take runs first so the guard has a working point to
# roll back to the moment it exists.
#
# THE TREE COMES FIRST, AS ROOT. The transaction lives under $SYS_DATA_DIR,
# the guard is placed into $BIN_DIR, and decide_bin_place_elevated probes
# $BIN_DIR's writability — every one of those needs the tree to exist already,
# root-owned with its modes stated, or an unprivileged step creates it on a
# host whose /usr/local the user owns. See ensure_system_tree.
ensure_system_tree || exit 1
txn_begin
snapshot_take
guard_arm

# ---- Phase 1: replace ------------------------------------------------------
# armed -> replacing. Everything from here on is a write the snapshot above
# can undo, and Phase 2 (verification, Task 8) checks before anything is
# restarted. This script advances the phase file itself up to here; past the
# handoff (Task 9) the guard owns every further transition.
txn_phase replacing

place_all_bins

"$BIN_DIR/@DISPATCHER@" --version 2>/dev/null || true

# Write both SYSTEM service units (single-slot consent first, then migrate any
# legacy per-user units out of the way). The state migration runs before
# render_units, not between it and loading them: a failed migration exits
# here, and a root-scheme unit left behind by an aborted run is bootstrapped by
# launchd at the next reboot regardless of what this run reported.
check_service_override
@STABLE_ONLY_BEGIN@
remove_legacy_user_units
@STABLE_ONLY_END@
# The migration's own consent gate, asked BEFORE the stop rather than at the
# restart below — on a host with a pending rung the runner stops the daemon and
# the operator's tunnelled session goes with it, and the Phase 3 prompt would
# then be read from a terminal that no longer exists. Silent when nothing is
# pending, and never asked at all on a run with no tty: see
# should_ask_before_migration.
@STABLE_ONLY_BEGIN@
if should_ask_before_migration; then
    consent_to_sever migration
fi
migrate_from_legacy
@STABLE_ONLY_END@

# Keep this installer + its migrations at $GW_HOME so subsequent `service install`
# verbs can re-render units and run a pending migration without a new download.
#
# AFTER migrate_from_legacy, never before. This function mkdir -p's $GW_HOME, and
# the runner's "$GW_HOME does not exist" guard is the only thing standing between
# `curl … | sudo sh` and a silently mis-targeted migration under ROOT's $HOME:
# under sudo $GW_HOME is /var/root/.burrowee/gateway, a tree the enrolled user
# never had. Running first, this created that tree — so the guard was asked a
# question whose answer this script had already falsified, on every entry point.
# The observed result was a clean-looking "no recorded version, and --applies
# does not recognise …", root-scheme units written AND loaded, the version anchor
# written into root's tree, exit 0, and a daemon that then refused to start.
keep_installer_copy

@BETA_ONLY_BEGIN@
seed_beta_config
@BETA_ONLY_END@
render_units

# load_units USED TO run right here, restarting the daemon in the foreground —
# on the very connection an operator tunnelled through that gateway is reading
# this output over. That restart now belongs to the guard armed above: it
# already holds the snapshot and the transaction, and it can roll back if the
# new build never comes back up, which this shell cannot do once its own
# session is the thing that just dropped. Task 9 adds the handoff that starts
# it; this script's job stops at leaving the units rendered and every step
# below — the ones a severed session used to skip — already done first.
#
# sweep_stale_user_bins does NOT move earlier to sit beside this comment: it
# deletes per-user binaries, and until the daemon has actually restarted onto
# the loaded units, a still-running per-user process may still name one.
# Task 10 runs it inside the guard, after a verified restart, never here.

# report_unrecorded_migration and record_installed_version used to run AFTER
# load_units — exactly the code a severed session never reached. A host cut
# off at the restart kept its new binaries and its migrated state, but its
# version anchor still named the OLD release, because the write that records
# it sat on the far side of the sever point. record_installed_version is what
# the NEXT run's migration gate reads, so a stale anchor there doesn't just
# mis-report this run — it feeds the wrong floor into every run after it.
# Both now run here, before the restart is even handed off, so a severed
# session has already banked them.
report_unrecorded_migration

# Record the ladder's version anchor here too. Fresh mode never did, which left
# the anchor written from exactly ONE place platform-wide (update mode, and only
# with --version) — so essentially every host reached a future rung through the
# runner's --applies fallback, the path its own header calls exceptional. The
# outer bootstrap passes the resolved release tag as BURROWEE_VERSION; a run
# without it (a hand-invoked inner installer) records nothing and keeps today's
# behaviour rather than inventing a version.
if [ "$MIGRATE_UNRECORDED" = "0" ]; then
    record_installed_version "${BURROWEE_VERSION:-}"
fi

# ---- Phase 2: verify -------------------------------------------------------
#
# Both failures go through abort_install, and neither restores or marks the

# transaction terminal itself — see that function's header. The old shape's
# "nothing was restarted; the running gateway was not disturbed" was false on
# a migrating host, where the daemon has been down since migrate_from_legacy.
verify_placement || abort_install "placement verification failed"
verify_units     || abort_install "unit verification failed"

txn_phase verified
echo "verified: binaries and units are in place and consistent"

# ---- first-run bootstrap (interactive only, fresh installs) -------------------
# Re-install short-circuit: if this host already holds gateway STATE it is
# already set up — never re-prompt for a setup blob. Otherwise read blob+PIN
# from the controlling terminal (stdin is the curl pipe, not a tty): prompt only
# if /dev/tty is genuinely usable (fd 3); if not (CI / detached) just print the
# next step. All tty I/O is fault-tolerant so it can never abort the install.
#
# gateway_already_set_up probes for the state itself, never for a non-empty
# $COMP_HOME. keep_installer_copy above creates that directory and writes
# install.sh + migrations/ into it a few dozen lines earlier, so "non-empty" is
# something THIS script guarantees: on a genuinely virgin host the old test
# printed "already set up — skipping setup" and the blob + PIN prompt never ran.
#
# Both layouts count. Pre-0.2.0 state lives in the per-user tree; on a migrated
# or root-installed host the identity and the store are under the SYSTEM roots
# and $COMP_HOME holds nothing but the installer copy — so a probe that looked
# only at $COMP_HOME would re-prompt a fully enrolled 0.2.x host.
gateway_already_set_up() {
    for _p in \
        "$COMP_HOME/identity/relay_ed.key" \
        "$COMP_HOME/keys/relay_ed.key" \
        "$COMP_HOME/gateway.db" \
        "$SYS_CONFIG_DIR/identity/relay_ed.key" \
        "$SYS_DATA_DIR/gateway.db"
    do
        if [ -e "$_p" ]; then return 0; fi
    done
    return 1
}

if gateway_already_set_up; then
    echo "$COMP already set up — skipping setup."
elif ( exec 3<>/dev/tty ) 2>/dev/null; then
    # PROBED IN A SUBSHELL, then opened for real. dash treats a FAILED `exec`
    # redirection as fatal and exits the script — status 2, no message the
    # `2>/dev/null` did not swallow — even inside a guarded `{ …; }` used as an
    # `if` condition. /bin/sh IS dash on every Debian-family host, and this is
    # the LAST step of an otherwise complete install, so on exactly the hosts
    # that matter the shape it replaces turned every non-interactive install
    # (CI, a console push, `curl … | sh` under a supervisor) into a fully
    # installed gateway reporting failure. has_tty above already probes this
    # way, for this reason.
    exec 3<>/dev/tty
    # Same reason as the consent prompt's: this read can block for as long as
    # the operator takes to find the blob, and the guard's deadline must not
    # mistake that for a wedge.
    heartbeat_start
    printf '\nSet up now? Paste the setup blob + PIN from the console (Enter to skip).\n' >&3 2>/dev/null || true

    printf 'blob> ' >&3 2>/dev/null || true
    blob=''; IFS= read -r blob <&3 2>/dev/null || blob=''
    if [ -n "$blob" ]; then
        printf 'pin>  ' >&3 2>/dev/null || true
        pin=''; IFS= read -r pin <&3 2>/dev/null || pin=''
        if [ -n "$pin" ]; then
            "$BIN_DIR/@DISPATCHER@" "$COMP" bootstrap "$blob" "$pin" <&3 || true
        else
            printf 'No PIN — skipped. Run later: @DISPATCHER@ %s bootstrap <blob> <pin>\n' "$COMP" >&3 2>/dev/null || true
        fi
    else
        printf 'Skipped. Run later: @DISPATCHER@ %s bootstrap <blob> <pin>\n' "$COMP" >&3 2>/dev/null || true
    fi
    heartbeat_stop
    exec 3>&- 2>/dev/null || true
else
    echo "next: @DISPATCHER@ $COMP bootstrap <blob> <pin>"
fi

# ---------------------------------------------------------------------------
# Phases 3-5: consent, handoff, reattach — the last things this script does on
# the full-install path.
#
# THE RESTART NO LONGER HAPPENS HERE. It used to be proved synchronously,
# right at this point in the script, by waiting on running.json
# ($SYS_DATA_DIR — never $SYS_CONFIG_DIR; runtime_version.WriteRunning writes
# to cfg.paths.Home, the DATA dir, internal/gateway/home.go) after load_units
# restarted the daemon in this shell's own foreground. That restart is the
# guard's job now (guard_arm, armed back at Phase 0), specifically so this
# script's foreground can be the thing that dies without changing the outcome
# — and guard.sh's own running_version() reads that identical path
# (tools/install-waits-for-daemon.test.sh asserts guard.sh agrees with the
# daemon on it, the same way it once asserted this script did).
# ---------------------------------------------------------------------------

# Phases 3-5 exist only when a guard is watching. Under BURROWEE_NO_RESTART
# (see guard_arm) nothing was armed, so there is nobody to consent to, nobody
# to hand off to, and nobody to reattach to — the units are staged on disk and
# that is the whole outcome. Skipping them is what makes the flag mean what
# this file has always documented it to mean.
#
# `!= 0`, not `= 1`: GUARD_ARMED is also `unproven` (see its declaration), which
# means the supervisor ACCEPTED the guard and only the proof was blind. A guard
# that really did start is watching a deadline, and skipping the handoff would
# leave it to time out and roll a healthy host back — so the handoff fires on
# both non-zero states. What `unproven` changes is abort_install, which may not
# hand its undo to a guard nobody saw, not whether the restart happens.
_verdict=0
if [ "$GUARD_ARMED" != 0 ]; then
    # ---- Phase 3: consent --------------------------------------------------
    consent_to_sever restart

    # ---- Phase 4: hand off -------------------------------------------------
    # Printed BEFORE the handoff, never after: once the guard restarts the
    # gateway, this connection — tunnelled through the very daemon being
    # restarted — may already be gone, and a line printed into a dead
    # connection reaches no one.
    echo ""
    echo "handing the restart to the guard. If this connection drops, reconnect and run:"
    echo "    @DISPATCHER@ gateway service guard-status"
    echo ""
    txn_phase handoff

    # ---- Phase 5: reattach -------------------------------------------------
    # Follow the guard to its verdict when the connection survives; if it does
    # not, the guard finishes the job regardless (reattach's own header).
    #
    # `|| _verdict=$?`, never a bare call followed by `_verdict=$?`: this
    # script runs under `set -e`, so a bare `reattach` returning 1 (rolled
    # back) or 2 (the rollback failed) ABORTS here — skipping the doctor tail
    # below, whose own header promises it runs "on every reattach outcome
    # alike". The two outcomes that most need a diagnostic report were the two
    # that never got one. C2 makes both of them ordinary rather than rare, so
    # the comment and the code agree now.
    reattach || _verdict=$?
else
    echo ""
    echo "units staged on disk. Nothing was restarted (BURROWEE_NO_RESTART)."
    echo "start the gateway when you are ready with:"
    echo "    sudo @DISPATCHER@ gateway service install"
    echo ""
fi

# ---- doctor, unconditionally ------------------------------------------------
# On every reattach outcome alike — served, rolled back, still running, or
# unreported. reattach answers one bit; doctor is the report an operator acts
# on, and it is the only thing that says what the daemon is actually doing
# once this session has reattached (or given up waiting).
#
# ITS EXIT STATUS IS NOT THIS INSTALL'S. The verdict is reattach's, from the
# guard; a read-only `doctor` reports failing rows through its own exit code,
# which is a diagnostic doing its job and not a second verdict on the install.
#
# STDIN IS /dev/null so it can neither prompt nor elevate. doctor's elevation
# gate is `euid != 0 && stdin is a terminal` (gw.MayElevate,
# cmd/burrowee-gateway-cli/doctor_elevate.go), and a non-terminal stdin makes it
# false whoever is running — which matters here more than for the other two
# components, since this script does not require root of itself and reaches
# privileged work through run_root. Only `--fix` remediates or prompts, and this
# is the read-only verb.
"$BIN_DIR/burrowee-gateway-cli" doctor < /dev/null || true

# ---- the last thing printed on a SUCCESSFUL install ------------------------
# The operator's own next step: how to reach $BIN_DIR from the shell they
# actually use. Printed unconditionally on success, including on a re-install
# that changed nothing — under `sudo` this process sees root's secure_path and
# cannot observe the operator's interactive PATH, so "is it already on PATH?"
# is a question it must not pretend to have answered.
#
# ON SUCCESS ONLY. A non-zero verdict means the guard rolled the host back to
# the build it was already running, and telling that operator how to reach a
# tree this run just reverted would be advice about an install that did not
# happen.
if [ "$_verdict" = 0 ]; then
    print_path_advice
fi

# reattach's verdict, and nothing after it: 0 served / handed off unreported,
# 1 rolled back or aborted with nothing started, 2 rollback itself failed (see
# reattach's own header for the exact mapping).
exit "$_verdict"

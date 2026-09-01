#!/bin/sh
# Burrowee inner installer — gateway (POSIX sh).
#
# Ships at the ROOT of the verified release zip as `install.sh`. The outer
# bootstrap verifies the zip (minisign + sha256) and ONLY THEN execs this with
# cwd = the unzipped dir, so the binaries sit alongside this script. It installs
# them into $BIN_DIR — /usr/local/bin, root-owned, ALWAYS — with the placement
# elevated via run_root the same way a root-owned tree always required. As of
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
# ONE BINARY LOCATION. Every binary, including the ones something running AS
# ROOT execs with nobody watching (the daemon, the console child it spawns, the
# updater agent, the cli the migration shells to), lands in $BIN_DIR — the same
# directory this script and its migrations/ are kept in too. This used to be
# two directories: a per-user $BIN_DIR and a root-owned $LIBEXEC_DIR, kept apart
# because $BIN_DIR's default was $HOME/.local/bin, and a root unit naming a
# per-user path is a permanent uid-0 grant to that user (overwrite the binary,
# wait for a reboot or a pushed update). Now that $BIN_DIR is always
# root-owned, a root-owned $BIN_DIR/burrowee-gateway passes the identical
# root-secure ancestor walk the separate tree existed to guarantee — the split
# had no job left, and /usr/local/libexec/burrowee/gateway is retired: a
# pre-existing one is simply never written to again and is left for an
# operator to remove by hand — this script does not touch it.
#
# THE SURVIVING INVARIANT (ensure_root_exec_surface / verify_root_exec_surface,
# unchanged in kind): only a path that is root-owned and unwritable by non-root
# ALL THE WAY TO / may be named in a unit or execed by the root updater. That
# still refuses on a contested $BIN_DIR (an Intel Mac where Homebrew chowns
# /usr/local, say) exactly as the old libexec check did — both paths share
# /usr/local as an ancestor, so nothing about that refusal got weaker.
#
# WHY THE DEFAULT MOVED AT ALL: something outside this component now execs
# `burrowee` off PATH as root to find this gateway — a plain PATH binary a
# unprivileged user could otherwise overwrite is a standing uid-0 grant to
# whoever owns it, even though no burrowee UNIT ever execs it as root. A
# root-owned $BIN_DIR is what makes that PATH lookup safe to trust.
#
# WHY THE PER-USER FLOW IS GONE, not merely de-defaulted. The PREFIX branch did
# not only put binaries somewhere else: it switched OFF the entire privileged
# surface — ensure_root_exec_surface, render_units, load_units,
# migrate_from_legacy and record_installed_version all gated on it — and the
# outer bootstrap defaulted PREFIX to $HOME/.local on every `curl … | sh`, so
# that branch was not the exception, it was the only path anyone took.
# Observed on a production node, 2026-08-13: burrowee sat at
# /home/ubuntu/.local/bin/burrowee while a consumer's ROOT daemon resolved the
# absolute /usr/local/bin/burrowee — correctly, since its unit pins
# PATH=/usr/bin:/bin:/usr/sbin:/sbin and a PATH lookup can reach nothing else.
# That daemon crash-looped 50 times on "resolve register socket" while
# `burrowee gateway doctor` reported a perfectly healthy gateway with 109h
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

# ONE DESTINATION, decided here and nowhere else: /usr/local/bin, root-owned.
# There is no branch left to take — every step below that treats $BIN_DIR as the
# privileged surface (ensure_root_exec_surface, render_units, load_units,
# migrate_from_legacy, record_installed_version) now runs on EVERY install,
# because there is no longer an install shape for which it would be wrong.
#
# BURROWEE_BIN_DIR is the surviving TEST-ONLY seam, and the only one: it
# redirects this destination so the suite never writes into the real
# /usr/local/bin. Never set it on a real host — nothing about the install's
# meaning changes when it is set, which is exactly why it is safe for tests and
# useless as a user-facing knob.
#
# Resolved BEFORE the PREFIX gate below, because the gate's whole question is
# "does this PREFIX name the destination we would have picked anyway?" — it
# cannot ask that without $BIN_DIR. This is an assignment only: nothing is
# created, placed or written until well after the gate.
BIN_DIR="${BURROWEE_BIN_DIR:-/usr/local/bin}"

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
        # /usr/local/bin (production truth, and what the suite's static pins
        # check) and the resolved $_true_bin. They differ only when the
        # BURROWEE_BIN_DIR test seam is set, and an operator reading a refusal on
        # a real host must see the real path either way.
        #
        # printf, not echo, on the two lines that interpolate caller-controlled
        # text: a PREFIX containing a backslash escape ('\c' ends echo's output
        # in dash) would otherwise truncate the refusal at the moment it quotes
        # the offending value, hiding the component, the destination and the
        # "nothing has been installed" line all at once.
        printf '%s\n' "install: PREFIX is set to '$PREFIX', but as of gateway 0.2.0 this installer" >&2
        echo "install: has one destination: /usr/local/bin, root-owned. The per-user prefix" >&2
        echo "install: flow is gone — the gateway's service units run as root and name the" >&2
        echo "install: binaries absolutely, and other components resolve /usr/local/bin/burrowee" >&2
        echo "install: by absolute path, so a per-user copy is invisible to both." >&2
        printf '%s\n' "install: (a PREFIX resolving to $_true_bin is honoured; '$_prefix_bin' is not it.)" >&2
        echo "hint: unset PREFIX and re-run; nothing has been installed." >&2
        exit 1
    fi
    unset _prefix_bin _true_bin
fi
BINS="burrowee burrowee-gateway burrowee-gateway-cli burrowee-gateway-console burrowee-register burrowee-gateway-updater"
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
# holds as systemConfigDir/systemDataDir (internal/gateway/home.go). They are
# written into the units, so they must not drift from that pair. Same test-seam
# caveat as above.
SYS_CONFIG_DIR="${BURROWEE_SYSTEM_CONFIG_DIR:-/usr/local/etc/burrowee/gateway}"
SYS_DATA_DIR="${BURROWEE_SYSTEM_DATA_DIR:-/usr/local/var/burrowee/gateway}"
SYS_LOG_DIR="$SYS_DATA_DIR/logs"

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
# THE PRIVILEGED EXECUTION SURFACE, collapsed into $BIN_DIR (formerly a separate
# root-owned tree at /usr/local/libexec/burrowee/gateway, sibling of the system
# config/data roots — retired now that $BIN_DIR's own default is root-owned; see
# the header comment for why the split had no job left). A host that already
# carries that tree keeps it, inert: nothing here ever writes to it again, and
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
# burrowee and burrowee-register are NOT here: nothing running as root execs
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
    echo "hint: re-run from an interactive terminal, or pre-authorize with 'sudo -v', then retry ('burrowee gateway service install')." >&2
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
#      that must not be answered with 1's message. It is reachable, since
#      ROOT_BIN_PLACE_EXCLUDE (BURROWEE_UPDATE mode) deliberately leaves
#      burrowee-gateway-updater unplaced this run, verify_root_exec_surface
#      checks it anyway (a unit is about to name it either way), and a host
#      converging off the pre-collapse layout has never had one at $BIN_DIR —
#      "not root-owned" would blame ownership on a path that was never
#      created, sending an operator to check permissions on nothing.
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

# ---------------------------------------------------------------------------
# root_bin_source <name> — where this run's copy of a root-execed binary comes
# from: the unzipped bundle when there is one (fresh + update modes place
# binaries), otherwise a copy already on disk — either the DEFAULT $BIN_DIR
# established by a previous run, or, for a host converging off the pre-collapse
# layout, the historical per-user default ($HOME/.local/bin, install.sh's own
# default before this DEFAULT moved to a root-owned $BIN_DIR).
#
# The second source is what converges a host installed under 0.2.0 whose $BIN_DIR
# already IS today's default: `burrowee gateway service install` re-runs the kept
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
    run_root mkdir -p "$BIN_DIR" || return 1
    # chown/chmod are best-effort: a tree root already established correctly
    # needs neither, and re-tightening one somebody else owns is not this
    # installer's call. The verification below is what decides, not these.
    run_root chown 0:0 "$BIN_DIR" 2>/dev/null || true
    run_root chmod 0755 "$BIN_DIR" 2>/dev/null || true

    for _reb in $ROOT_BINS; do
        if [ -n "$ROOT_BIN_PLACE_EXCLUDE" ] && [ "$_reb" = "$ROOT_BIN_PLACE_EXCLUDE" ]; then
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
# aimed at $BIN_DIR instead of a separate tree (see the header comment for why
# the tree itself had no job left once $BIN_DIR's default became root-owned).
# /usr/local is root-owned on a modern macOS and on every Linux, but it is not
# GUARANTEED to be: a host where a package manager chowned it (Homebrew on
# Intel macOS) would otherwise get a root-scheme unit pointing into a path its
# owner can rewrite. That refusal is UNCHANGED by the collapse: /usr/local was
# already the ancestor both the old tree and the new one walk through.
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
            echo "hint: system one; then re-run 'burrowee gateway service install'." >&2
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
            echo "hint: 'burrowee gateway service install' to place it and converge the host;" >&2
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
}

# ---------------------------------------------------------------------------
# Single system slot: unit ownership + cross-user override consent.
# ---------------------------------------------------------------------------
core_unit_path() {
    case "$(uname -s)" in
    Darwin) echo "$LAUNCHD_DIR/com.burrowee.gateway.plist" ;;
    *)      echo "$SYSTEMD_DIR/burrowee-gateway.service" ;;
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
    echo "hint: re-run with BURROWEE_FORCE_SERVICE_OVERRIDE=1 (or 'burrowee gateway service install --force-service-override') to take it over." >&2
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
# a normal PATH, so every unqualified `burrowee` or `burrowee-gateway-cli` an
# operator types keeps resolving to the OLD binary while the units and every
# absolute-path consumer use the new one — the same split-brain the header's
# outage describes, read from the other end. Observed on a production node the
# day 0.2.1 shipped: `which burrowee` → /home/ubuntu/.local/bin/burrowee.
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
        if [ "$BINS" != "$STALE_USER_BINS" ]; then
            echo "note: this installer places [$BINS]" >&2
            echo "note: but $_ssub_lib sweeps [$STALE_USER_BINS]." >&2
            echo "note: the two lists disagree, so some name is installed and never swept" >&2
            echo "note: (it keeps shadowing $BIN_DIR on PATH) or swept and never installed." >&2
        fi
    fi
    remove_stale_user_bins
}

# ---------------------------------------------------------------------------
# place_unit <rendered-temp-file> <dst> — install a rendered unit at its
# system path as root, only when content differs (a no-op refresh never needs
# sudo). Must stay content-identical with the Go side's unit writers.
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
    echo "service unit: $2"
}

# ---------------------------------------------------------------------------
# ensure_system_log_dir — pre-create the units' log directory under the SYSTEM
# data root, as root.
#
# launchd applies StandardOutPath at exec, so a missing parent is not a log
# that appears late — it is a daemon that fails to spawn. Creation goes through
# run_root because a NON-ROOT process must never create the root daemon's data
# root: on a host where /usr/local/var is writable by the installing user
# (Intel macOS, where Homebrew chowns it) an unprivileged mkdir succeeds and
# leaves the root daemon's gateway.db and register/console sockets inside a
# directory that user fully controls.
#
# 0700 is set explicitly, and only on the directories this created: mkdir -p
# applies the process umask (0755 on a typical host, which would leave the
# store world-readable), and re-tightening a root somebody else already
# established is not this installer's call. Never fatal — the daemon creates
# the tree on first start, so a missing sudo costs a log file, not an install.
# ---------------------------------------------------------------------------
ensure_system_log_dir() {
    if [ -d "$SYS_LOG_DIR" ]; then return 0; fi
    _data_root_existed=0
    if [ -d "$SYS_DATA_DIR" ]; then _data_root_existed=1; fi
    if ! run_root mkdir -p "$SYS_LOG_DIR"; then
        echo "note: could not create $SYS_LOG_DIR (needs root) — the gateway creates it on first start" >&2
        return 0
    fi
    if [ "$_data_root_existed" = 0 ]; then
        run_root chmod 0700 "$SYS_DATA_DIR" 2>/dev/null || true
    fi
    run_root chmod 0700 "$SYS_LOG_DIR" 2>/dev/null || true
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
# migration_sudo — the elevation command handed to the runner, following THIS
# script's own root policy (run_root): a prompting `sudo` only when there is a
# controlling tty to prompt on, `sudo -n` otherwise. An explicit SUDO from the
# caller wins, so the updater's own seam still reaches the runner.
#
# The documented install flow is `curl … | sh`, where stdin is the pipe. A bare
# `sudo` there fails with "no tty present and no askpass program" — and it fails
# AFTER the runner has stopped the gateway, with none of run_root's hint text.
# ---------------------------------------------------------------------------
migration_sudo() {
    if [ -n "${SUDO:-}" ]; then echo "$SUDO"; return 0; fi
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
# The $BIN_DIR copy is guarded on $SYS_CONFIG_DIR, which since the prefix flow
# was removed is the whole question: $BIN_DIR is the system location on every
# install, so what is left to ask is whether this host has actually been
# converged to the root scheme yet. A host with no system config root has no
# root-scheme updater reading that copy, and writing it would root-own a file in
# a tree nothing on this host consults.
record_installed_version() {
    _ver="${1##*/}"
    if [ -z "$_ver" ]; then return 0; fi
    mkdir -p "$GW_HOME"
    printf '%s\n' "$_ver" > "$GW_HOME/.installed-version"
    if [ -d "$SYS_CONFIG_DIR" ]; then
        printf '%s\n' "$_ver" | run_root tee "$BIN_DIR/.installed-version" >/dev/null || true
    fi
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
# cannot migrate — and `burrowee gateway service install` is the remedy this
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
            echo "note: 'burrowee gateway service install' will not be able to migrate." >&2
        fi
    fi
    # guard.sh too, off the same resolution guard_arm itself uses
    # ("$(dirname "$0")/guard.sh"): a units-only re-run's $0 IS the kept
    # $GW_HOME/install.sh, so without this copy that later run would find no
    # guard beside it and refuse to arm at all.
    _src_guard="$(dirname "$0")/guard.sh"
    if [ -f "$_src_guard" ]; then
        if ! cp "$_src_guard" "$GW_HOME/guard.sh" 2>/dev/null; then
            echo "note: could not keep a copy of guard.sh at $GW_HOME — a later" >&2
            echo "note: 'burrowee gateway service install' will not be able to arm the guard." >&2
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
        ensure_system_log_dir

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
  <key>Label</key><string>com.burrowee.gateway</string>
  <key>ProgramArguments</key><array><string>$BIN_DIR/burrowee-gateway</string><string>--no-open</string><string>--config-dir</string><string>$SYS_CONFIG_DIR</string><string>--data-dir</string><string>$SYS_DATA_DIR</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>WorkingDirectory</key><string>/tmp</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>PathState</key><dict><key>$BIN_DIR/burrowee-gateway</key><true/></dict></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$SYS_LOG_DIR/gateway.log</string>
  <key>StandardErrorPath</key><string>$SYS_LOG_DIR/gateway.err.log</string>
</dict></plist>
EOF
        place_unit "$_tmp_unit" "$LAUNCHD_DIR/com.burrowee.gateway.plist"

        # Updater unit. No path flags: the updater agent resolves its own roots,
        # which already default to the system pair under root's euid — the same
        # defaulting the core unit's flags only make explicit.
        _tmp_unit="$(mktemp)"
        cat > "$_tmp_unit" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.burrowee.gateway.updater</string>
  <key>ProgramArguments</key><array><string>$BIN_DIR/burrowee-gateway-updater</string><string>run</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>WorkingDirectory</key><string>/tmp</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>PathState</key><dict><key>$BIN_DIR/burrowee-gateway-updater</key><true/></dict></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$SYS_LOG_DIR/updater.log</string>
  <key>StandardErrorPath</key><string>$SYS_LOG_DIR/updater.err.log</string>
</dict></plist>
EOF
        place_unit "$_tmp_unit" "$LAUNCHD_DIR/com.burrowee.gateway.updater.plist"
        ;;

    Linux)
        ensure_system_log_dir

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
ExecStart=$BIN_DIR/burrowee-gateway --no-open --config-dir $SYS_CONFIG_DIR --data-dir $SYS_DATA_DIR
Restart=always
RestartSec=2
TimeoutStopSec=330

[Install]
WantedBy=multi-user.target
EOF
        place_unit "$_tmp_unit" "$SYSTEMD_DIR/burrowee-gateway.service"

        # Updater unit. No path flags: the updater agent resolves its own roots,
        # which already default to the system pair under root's euid — the same
        # defaulting the core unit's flags only make explicit.
        _tmp_unit="$(mktemp)"
        cat > "$_tmp_unit" <<EOF
[Unit]
Description=burrowee-gateway-updater
After=network-online.target

[Service]
ExecStart=$BIN_DIR/burrowee-gateway-updater run
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
        place_unit "$_tmp_unit" "$SYSTEMD_DIR/burrowee-gateway-updater.service"
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
# WHO REACHES THIS, and it is a short list — every restart below inherits it:
#   fresh install (default mode)   an operator install; every binary was just
#                                  re-placed unconditionally a few lines earlier
#   BURROWEE_UNITS_ONLY            `gateway service install` / the offline
#                                  LocalReinstall — an operator/console verb
# and, decisively, who does NOT:
#   BURROWEE_UPDATE                the updater's own push path. It calls
#                                  render_units and never load_units, because
#                                  the process running this script is the one
#                                  a restart here would kill mid-update. That
#                                  exclusion is structural, not a flag — do not
#                                  add a load_units call to that branch.
#   BURROWEE_UNINSTALL             tears units down on its own terms.
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
            run_root launchctl bootstrap system "$LAUNCHD_DIR/com.burrowee.gateway.plist"         2>/dev/null || true
            run_root launchctl bootstrap system "$LAUNCHD_DIR/com.burrowee.gateway.updater.plist" 2>/dev/null || true
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
            start_unit_darwin "com.burrowee.gateway" "$LAUNCHD_DIR/com.burrowee.gateway.plist"
            SERVE_UNIT_STARTED=1
            if [ -n "${BURROWEE_NO_UPDATER:-}" ]; then
                echo "note: BURROWEE_NO_UPDATER set — updater unit staged, not started" >&2
            else
                run_root launchctl bootout "system/com.burrowee.gateway.updater" 2>/dev/null || true
                # Recorded, not fatal — see UPDATER_START_FAILED.
                start_unit_darwin "com.burrowee.gateway.updater" "$LAUNCHD_DIR/com.burrowee.gateway.updater.plist" \
                    || UPDATER_START_FAILED=1
            fi
        fi
        ;;
    Linux)
        run_root systemctl daemon-reload 2>/dev/null || true
        if [ -n "${BURROWEE_NO_RESTART:-}" ]; then
            run_root systemctl enable burrowee-gateway.service         2>/dev/null || true
            run_root systemctl enable burrowee-gateway-updater.service 2>/dev/null || true
            echo "note: BURROWEE_NO_RESTART set — units staged (not restarted)" >&2
        else
            run_root systemctl enable --now burrowee-gateway.service         2>/dev/null || true

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
            # host in drift today reaches `burrowee gateway service install` with
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
            if ! run_root systemctl restart burrowee-gateway.service; then
                echo "error: 'systemctl restart burrowee-gateway.service' failed — the newly" >&2
                echo "error: installed binaries are on disk, but the daemon still running is the" >&2
                echo "error: OLD one. 'burrowee gateway doctor' reports installed/running drift" >&2
                echo "error: until it is restarted, and a unit rewritten to a new ExecStart has" >&2
                echo "error: not taken effect." >&2
                echo "hint: restart it by hand: sudo systemctl restart burrowee-gateway.service" >&2
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
            if run_root systemctl is-active --quiet burrowee-gateway.service; then
                echo "systemd service burrowee-gateway.service enabled + (re)started"
                SERVE_UNIT_STARTED=1
            else
                echo "error: burrowee-gateway.service is not active after enable --now" >&2
                echo "hint: sudo systemctl status burrowee-gateway.service" >&2
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
                start_unit_linux burrowee-gateway-updater.service || UPDATER_START_FAILED=1
            fi
        fi
        ;;
    esac
}

# ---------------------------------------------------------------------------
# finish_with_updater_verdict — the last statement of every mode that calls
# load_units. Exits 0 when the updater started (or was never asked to), and 1
# when its start failed, having let everything after load_units run first.
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
#     guard.pid      so a second install can refuse to race a live guard
#     installer.pid  what the guard watches for an early death
#     snapshot/      bin/ units/ config/ data/
# ---------------------------------------------------------------------------
TXN_DIR=""
TXN_STAMP=""

txn_begin() {
    TXN_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
    TXN_DIR="$SYS_DATA_DIR/install/$TXN_STAMP"
    run_root mkdir -p "$TXN_DIR/snapshot/bin" "$TXN_DIR/snapshot/units" || return 1
    run_root chmod 700 "$SYS_DATA_DIR/install" "$TXN_DIR" || return 1
    printf '%s\n' "$$" | run_root tee "$TXN_DIR/installer.pid" >/dev/null || return 1
    txn_phase armed
}

# txn_phase <phase> — the ONLY writer of the phase file, and it writes
# atomically. The guard polls this file; a partial write read as a phase name
# would be an unrecognised state, and the guard's default for an unrecognised
# state is to roll back. Write to a temp name in the same directory, then mv.
txn_phase() {
    [ -n "$TXN_DIR" ] || return 0
    printf '%s\n' "$1" | run_root tee "$TXN_DIR/.phase.tmp" >/dev/null || return 1
    run_root mv -f "$TXN_DIR/.phase.tmp" "$TXN_DIR/phase" || return 1
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
        for u in com.burrowee.gateway.plist com.burrowee.gateway.updater.plist; do
            [ -f "$LAUNCHD_DIR/$u" ] && { run_root cp -p "$LAUNCHD_DIR/$u" "$_snap/units/$u" || return 1; }
        done
        ;;
    Linux)
        for u in burrowee-gateway.service burrowee-gateway-updater.service; do
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
SNAPSHOT_CONSISTENCY=exact
snapshot_db() {
    _dst="$1"
    [ -f "$SYS_DATA_DIR/gateway.db" ] || return 0

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
# _guard is resolved beside THIS installer ("$(dirname "$0")/guard.sh"), the
# same way ensure_root_exec_surface resolves migrations/ — never
# "$GW_HOME/guard.sh". keep_installer_copy has not run yet when this is called
# (it runs after the migration, still ahead of us in the fresh-install flow),
# so $GW_HOME holds no guard.sh on a fresh host's first run; the copy it keeps
# is what a LATER `service install` re-run finds instead, off the very same
# expression.
#
# _libexec_dir has a BURROWEE_LIBEXEC_DIR test seam for the same reason
# BURROWEE_BIN_DIR exists: this suite must never write into the real
# /usr/local, and unlike $BIN_DIR/$LAUNCHD_DIR/$SYSTEMD_DIR this destination
# had no seam of its own to reuse. The production default is unchanged.
guard_arm() {
    _guard="$(dirname "$0")/guard.sh"
    if [ ! -f "$_guard" ]; then
        echo "error: guard.sh is not beside this installer — refusing to run an unguarded" >&2
        echo "error: install on a host that is currently serving as a gateway." >&2
        return 1
    fi
    _libexec_dir="${BURROWEE_LIBEXEC_DIR:-/usr/local/libexec/burrowee}"
    # mkdir -p first: neither GNU nor BSD `install` creates a missing parent
    # (GNU's -D does, but this file never assumes GNU), and a fresh host has no
    # reason to already carry this directory — the pre-collapse libexec tree
    # this sits beside is retired and never recreated (see this file's header).
    run_root mkdir -p "$_libexec_dir" || return 1
    run_root install -m 0755 "$_guard" "$_libexec_dir/gateway-guard" || return 1

    case "$(uname -s)" in
    Darwin)
        _gp="$LAUNCHD_DIR/com.burrowee.gateway.guard.plist"
        _tmp="$(mktemp)"
        cat > "$_tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.burrowee.gateway.guard</string>
  <key>ProgramArguments</key><array><string>$_libexec_dir/gateway-guard</string><string>$TXN_DIR</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>WorkingDirectory</key><string>/tmp</string>
  <key>RunAtLoad</key><true/>
  <key>AbandonProcessGroup</key><true/>
  <key>StandardOutPath</key><string>$TXN_DIR/guard.out</string>
  <key>StandardErrorPath</key><string>$TXN_DIR/guard.err</string>
</dict></plist>
EOF
        place_unit "$_tmp" "$_gp"
        # No KeepAlive: the guard runs once and is done. bootout FIRST, because
        # unlike the serve label this one is safe to unload — nothing routes
        # through it — and a stale guard job from a previous install would
        # otherwise refuse the bootstrap.
        run_root launchctl bootout "system/com.burrowee.gateway.guard" 2>/dev/null || true
        run_root launchctl bootstrap system "$_gp" || return 1
        ;;
    Linux)
        run_root systemd-run --unit=burrowee-gateway-guard --collect \
            "$_libexec_dir/gateway-guard" "$TXN_DIR" || return 1
        ;;
    *)
        echo "warning: no supervisor on $(uname -s) — the install is NOT guarded" >&2
        return 1
        ;;
    esac
    echo "guard armed — transaction $TXN_DIR"
}

# ---------------------------------------------------------------------------
# $BIN_DIR placement: one elevation decision, all-or-nothing.
#
# Mirrors gateway/update.sh's PLACE_ELEVATED (see that script's header for the
# full field history). $BIN_DIR was always writable under the old default
# ($HOME/.local/bin); it is root-owned under the new one (/usr/local/bin), so
# placing straight onto the final names with a bare `install` would die on the
# first binary for anyone who is not already root. The elevation is decided
# ONCE per mode, by a real create rather than assumed — a run already at uid 0,
# or a host whose /usr/local is writable by the invoking user, never pays for a
# sudo call it does not need — and every write of one placement goes through the
# SAME decision, so a set can never end up half-elevated.
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

# decide_bin_place_elevated — the real-create probe, once. mkdir -p first so a
# genuinely absent $BIN_DIR (fresh host, either default) does not read as
# "unwritable" for the wrong reason.
decide_bin_place_elevated() {
    if mkdir -p "$BIN_DIR" 2>/dev/null && bin_place_writable "$BIN_DIR"; then
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
        if have_real_root && ! path_is_root_secure "$BIN_DIR/$b"; then
            echo "verify: $BIN_DIR/$b is not root-secure" >&2; _rc=1; continue
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
        for u in com.burrowee.gateway.plist com.burrowee.gateway.updater.plist; do
            _p="$LAUNCHD_DIR/$u"
            [ -f "$_p" ] || { echo "verify: $_p is missing" >&2; _rc=1; continue; }
            if command -v plutil >/dev/null 2>&1 && ! plutil -lint "$_p" >/dev/null 2>&1; then
                echo "verify: $_p is not a valid plist" >&2; _rc=1
            fi
        done
        ;;
    Linux)
        for u in burrowee-gateway.service burrowee-gateway-updater.service; do
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
# Mode dispatch.
# ---------------------------------------------------------------------------

# Sourced by the test suites to reach the helpers above without performing an
# install. It is checked here, at the TOP of the mode dispatch, so no mode can
# be entered by a sourcing caller.
if [ -n "${BURROWEE_SOURCE_ONLY:-}" ]; then
    return 0 2>/dev/null || exit 0
fi

if [ -n "${BURROWEE_UNITS_ONLY:-}" ]; then
    # First, ahead of the consent prompt and every write: this mode places no
    # binaries at all, so the cli the runner will probe is the one already on
    # disk. If it cannot migrate, render_units below would leave root-scheme
    # units on a host whose state never moved.
    assert_can_migrate "$(migrate_cli_path)"
    check_service_override
    remove_legacy_user_units
    # Before render_units as well as before load_units. Before load_units because
    # the migration stops the gateway to copy its store at rest and load_units is
    # what starts it again; before render_units because a migration that fails for
    # ANY reason exits this script — and a root-scheme unit left on disk by a run
    # that then aborted is bootstrapped by launchd at the next reboot regardless,
    # against a config root the migration never populated.
    migrate_from_legacy
    render_units
    load_units
    # Only now: the units naming $BIN_DIR are not merely written, they are the
    # ones the supervisor is running. See sweep_stale_user_bins' header for why
    # this cannot move earlier.
    sweep_stale_user_bins
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
    # This mode calls load_units too, so it owns the same deferred verdict: the
    # anchor above is written first, and only then does a failed updater start
    # decide the exit status.
    finish_with_updater_verdict
fi

if [ -n "${BURROWEE_UPDATE:-}" ]; then
    # ------------------------------------------------------------------
    # Update mode: per-binary sha256 change detection, transactional swap.
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
    # happen later via 'burrowee gateway service install'.
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
        migrate_from_legacy
        render_units || echo "note: service units not refreshed (needs sudo) — run 'burrowee gateway service install'" >&2

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
        echo "note: not migrating either — 'burrowee gateway service install' takes the slot over first" >&2
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
        echo "note: or run 'burrowee gateway restart' now." >&2
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
        for b in $BINS; do
            if [ -e "$BIN_DIR/$b" ] && ! bin_place_run rm -f "$BIN_DIR/$b"; then
                _uninstall_failed="${_uninstall_failed:+$_uninstall_failed }$b"
            fi
        done
        # This script's own kept copy + migrations/, placed here by
        # ensure_root_exec_surface (never by BINS) — an uninstall that leaves
        # them behind hands the next install a root-owned installer it never
        # re-verified.
        [ -e "$BIN_DIR/install.sh" ] && { bin_place_run rm -f "$BIN_DIR/install.sh" || _uninstall_failed="${_uninstall_failed:+$_uninstall_failed }install.sh"; }
        [ -d "$BIN_DIR/migrations" ] && { bin_place_run rm -rf "$BIN_DIR/migrations" || _uninstall_failed="${_uninstall_failed:+$_uninstall_failed }migrations"; }
        [ -e "$BIN_DIR/.installed-version" ] && bin_place_run rm -f "$BIN_DIR/.installed-version"
    fi
    echo "removed from $BIN_DIR: $BINS"
    if [ -n "$_uninstall_failed" ]; then
        echo "note: could not remove from $BIN_DIR (needs root): $_uninstall_failed — remove by hand" >&2
    fi

    # A pre-existing /usr/local/libexec/burrowee/gateway tree, if this host has
    # one, is left in place — this script never wrote to it and does not clean
    # it up; that is an operator's call, by hand.

    # Remove the system service units (root) plus any legacy per-user units.
    # All best-effort: a missing unit or unavailable sudo must not stop uninstall.
    case "$(uname -s)" in
    Darwin)
        for _label in com.burrowee.gateway com.burrowee.gateway.updater; do
            if [ -f "$LAUNCHD_DIR/$_label.plist" ]; then
                run_root launchctl bootout "system/$_label" 2>/dev/null || true
                run_root rm -f "$LAUNCHD_DIR/$_label.plist" || true
            fi
        done
        ;;
    Linux)
        _removed=""
        for _unit in burrowee-gateway.service burrowee-gateway-updater.service; do
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
    remove_legacy_user_units

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
# stops the daemon itself (adopt_user_tree.sh) seventeen lines before load_units
# ever restarts it, severing a tunnelled operator's session at the migration,
# not the restart. snapshot_take runs first so the guard has a working point to
# roll back to the moment it exists.
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

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "note: $BIN_DIR is not on PATH — add: export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

"$BIN_DIR/burrowee" --version 2>/dev/null || true

# Write both SYSTEM service units (single-slot consent first, then migrate any
# legacy per-user units out of the way). The state migration runs before
# render_units, not between it and loading them: a failed migration exits
# here, and a root-scheme unit left behind by an aborted run is bootstrapped by
# launchd at the next reboot regardless of what this run reported.
check_service_override
remove_legacy_user_units
migrate_from_legacy

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
verify_placement || {
    echo "install: verification failed — restoring the previous install." >&2
    echo "install: nothing was restarted; the running gateway was not disturbed." >&2
    snapshot_restore || echo "install: the restore itself reported errors — see above" >&2
    txn_phase rolled-back
    exit 1
}
verify_units || {
    echo "install: unit verification failed — restoring the previous install." >&2
    snapshot_restore || echo "install: the restore itself reported errors — see above" >&2
    txn_phase rolled-back
    exit 1
}
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
# Prove the NEW daemon is serving, then report — the last thing this script does
# on the full-install path, because "hands back" is where the claim is made.
#
# THE PATH. burrowee-gateway writes running.json into
# runtime_version.WriteRunning(cfg.paths.Home, version)
# (cmd/burrowee-gateway/main.go), and GwPaths.Home is the DATA dir, not the
# config dir (internal/gateway/home.go: GatewayPaths sets Home: dataDir) — so it
# is $SYS_DATA_DIR here, never $SYS_CONFIG_DIR. Edge's own recordRunningVersion
# header records what the second spelling of this decision cost, one component
# over: a doctor reporting "the daemon is not running" about a daemon that was,
# for 35h on a production node. These two names must stay in step;
# tools/install-waits-for-daemon.test.sh asserts they do.
#
# Not on the BURROWEE_UNITS_ONLY, BURROWEE_UPDATE or BURROWEE_UNINSTALL paths:
# each exits above. Update mode in particular renders units and deliberately
# never loads them, so there is nothing there that a wait could be waiting for.
# ---------------------------------------------------------------------------
if [ "$SERVE_UNIT_STARTED" = 1 ]; then
    WANT_VERSION="$(binary_version_stamp "$BIN_DIR/burrowee-gateway")"
    if [ -n "$WANT_VERSION" ]; then
        # The timeout's status is deliberately dropped: this wait never fails an
        # install (see wait_for_running_version's contract).
        wait_for_running_version "$SYS_DATA_DIR" "$WANT_VERSION" || true
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
# further up; a read-only `doctor` reports failing rows through its exit code,
# which is a diagnostic doing its job and not a failed install. Hence the guard.
#
# STDIN IS /dev/null so it can neither prompt nor elevate. doctor's elevation
# gate is `euid != 0 && stdin is a terminal` (gw.MayElevate,
# cmd/burrowee-gateway-cli/doctor_elevate.go), and a non-terminal stdin makes it
# false whoever is running — which matters here more than for the other two
# components, since this script does not require root of itself and reaches
# privileged work through run_root. Only `--fix` remediates or prompts, and this
# is the read-only verb.
"$BIN_DIR/burrowee-gateway-cli" doctor < /dev/null || true

# ---- the deferred updater verdict, and nothing after it ---------------------
# Prints nothing and exits 0 on every healthy path. It sits below doctor because
# a broken delivery channel is precisely the failure an operator needs the
# diagnostic for; it sits at all because the exit status still has to report it.
finish_with_updater_verdict

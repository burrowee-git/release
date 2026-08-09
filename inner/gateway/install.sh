#!/bin/sh
# Burrowee inner installer — gateway (POSIX sh).
#
# Ships at the ROOT of the verified release zip as `install.sh`. The outer
# bootstrap verifies the zip (minisign + sha256) and ONLY THEN execs this with
# cwd = the unzipped dir, so the binaries sit alongside this script. It installs
# them into PREFIX/bin — DEFAULT /usr/local/bin, root-owned, placement elevated
# via run_root the same way a root-owned tree always required. Set PREFIX
# (e.g. $HOME/.local) for the unprivileged developer install, which still
# installs every binary unelevated. Set BURROWEE_UNINSTALL to remove them
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
# wait for a reboot or a pushed update). Now that $BIN_DIR's DEFAULT is itself
# root-owned, a root-owned $BIN_DIR/burrowee-gateway passes the identical
# root-secure ancestor walk the separate tree existed to guarantee — the split
# had no job left, and /usr/local/libexec/burrowee/gateway is retired (see
# remove_stale_libexec_tree for hosts converging off it).
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
# Nothing about the unprivileged developer flow changes: an explicit PREFIX
# still gets every binary in full, unelevated — it simply gets no units, which
# was already true.
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

# DEFAULT root-owned: this is what changed. An explicit PREFIX (the developer
# flow, e.g. $HOME/.local) still overrides in full and never elevates — see
# decide_bin_place_elevated below, which decides per run rather than assuming.
BIN_DIR="${PREFIX:-/usr/local}/bin"
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
# THE PRIVILEGED EXECUTION SURFACE, collapsed into $BIN_DIR (formerly a separate
# root-owned tree at /usr/local/libexec/burrowee/gateway, sibling of the system
# config/data roots — retired now that $BIN_DIR's own default is root-owned; see
# the header comment for why the split had no job left). OLD_ROOT_EXEC_DIR below
# is kept ONLY so an existing 0.2.0 host's stale tree can be found and removed,
# never written to again.
#
# The binaries a ROOT process execs unattended, and therefore the ones that must
# come from a path no unprivileged user can rewrite (verify_root_exec_surface):
#   burrowee-gateway          the daemon named in the core unit
#   burrowee-gateway-console  spawned + supervised by that daemon, from its own dir
#   burrowee-gateway-updater  the daemon named in the updater unit
#   burrowee-gateway-cli      execed as root by migrations/v1_to_v2.sh, which the
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
# The pre-collapse privileged tree. A $BURROWEE_*_DIR test seam like the other
# root paths above, for the same reason and one more: remove_stale_libexec_tree
# runs `rm -rf` through root elevation, and a test suite proving the
# rewrite-then-remove ORDER has to be able to point this at a throwaway
# directory it controls — this is real system state on a real host otherwise,
# and this codebase's tests must never touch that (see the sibling roots'
# BURROWEE_SYSTEM_CONFIG_DIR / BURROWEE_LAUNCHD_DIR seams for the same rule).
OLD_ROOT_EXEC_DIR="${BURROWEE_OLD_ROOT_EXEC_DIR:-/usr/local/libexec/burrowee/gateway}"

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
# THREE return codes, not two:
#   0  secure
#   1  not secure — a real answer about a real path
#   2  undecidable — stat did not answer, so nothing is known either way
#
# 1 and 2 are separated because they send an operator to completely different
# places, and collapsing them is what the dialect bug above actually cost: a
# host whose tree was already root:root 755 was told to go and check its
# permissions. A predicate guarding a root exec must still REFUSE on 2 — but it
# must refuse saying it could not look.
path_is_root_secure() {
    _rs_p="$1"
    [ -f "$_rs_p" ] || return 1
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
# remove_stale_libexec_tree — best-effort cleanup of the pre-collapse privileged
# tree ($OLD_ROOT_EXEC_DIR = /usr/local/libexec/burrowee/gateway), now superseded
# by $BIN_DIR.
#
# ORDER IS THE WHOLE POINT, and it is why every caller of this function is
# required to have ALREADY called render_units (which rewrites the unit to name
# $BIN_DIR) and load_units (which actually reloads/bootstraps it into the live
# supervisor) first. A host converging off the old layout still has its
# supervisor holding the OLD in-memory ExecStart — the one naming
# $OLD_ROOT_EXEC_DIR — until load_units's bootout+bootstrap (Darwin) or
# daemon-reload+restart (Linux) replaces it. Removing the tree before that
# reload happens would not be cleanup: the next KeepAlive/Restart respawn finds
# no binary at the path the supervisor still remembers, and a host that was
# running is now down. This is why BURROWEE_UPDATE mode, which refreshes the
# unit FILE but deliberately never reloads it (see load_units's header), must
# NEVER call this — its unit body may say $BIN_DIR while the running supervisor
# has not been told yet.
#
# Best-effort throughout: a leftover tree is stale and harmless, never a reason
# to fail an install that otherwise succeeded.
# ---------------------------------------------------------------------------
remove_stale_libexec_tree() {
    [ -d "$OLD_ROOT_EXEC_DIR" ] || return 0
    if run_root rm -rf "$OLD_ROOT_EXEC_DIR"; then
        echo "removed the superseded $OLD_ROOT_EXEC_DIR (binaries now live in $BIN_DIR)"
    else
        echo "note: could not remove the superseded $OLD_ROOT_EXEC_DIR (needs root) — harmless, remove it by hand" >&2
    fi
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
# migrate_cli_path — the cli the runner will actually probe. Both live in the
# same $BIN_DIR now, so there is exactly one candidate — but it must still be
# THIS function, not a literal at each call site, because it and the runner's
# own resolution have to agree, or this pre-flight passes on one binary while
# the runner refuses on another.
migrate_cli_path() {
    echo "$BIN_DIR/burrowee-gateway-cli"
}

assert_can_migrate() {
    if [ -z "$(migration_runner)" ]; then return 0; fi
    if [ -x "$1" ] && "$1" migrate --help >/dev/null 2>&1; then return 0; fi
    echo "error: this release's state migration needs 'burrowee-gateway-cli migrate'," >&2
    echo "error: and $1 does not provide it — refusing before anything is changed." >&2
    echo "hint: nothing has been touched: no binary was replaced and no service unit written." >&2
    echo "hint: install the current release first (it ships a cli that carries the verb):" >&2
    echo "hint:   curl -fsSL https://release.burrowee.com/gateway/install.sh | sh" >&2
    exit 1
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
# $BIN_DIR. One writer for both keeps them from disagreeing. Guarded on
# $SYS_CONFIG_DIR, not on $BIN_DIR's existence — $BIN_DIR always exists by this
# point on ANY install, root-scheme or not, so only the system-config marker
# distinguishes "this host has a privileged copy to keep in step" from "this is
# a per-user PREFIX install with nothing at $BIN_DIR for a root updater to read".
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
    # The runner shells to burrowee-gateway-cli AS ROOT (v1_to_v2.sh's `elevate
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
    GW_HOME="$GW_HOME" \
        PREFIX="${PREFIX:-$HOME/.local}" \
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
            run_root launchctl bootout   "system/com.burrowee.gateway"          2>/dev/null || true
            run_root launchctl bootstrap system "$LAUNCHD_DIR/com.burrowee.gateway.plist"         2>/dev/null || true
            run_root launchctl bootout   "system/com.burrowee.gateway.updater"  2>/dev/null || true
            run_root launchctl bootstrap system "$LAUNCHD_DIR/com.burrowee.gateway.updater.plist" 2>/dev/null || true
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
            # Loud on failure and not fatal. New binaries under an old daemon is
            # the one outcome that looks like a clean install and is not, so it is
            # never swallowed; but the units on disk are still the durable
            # outcome, and a supervisor-less host (a container) must still finish
            # the install — same contract as every other step here.
            if ! run_root systemctl restart burrowee-gateway.service; then
                echo "error: 'systemctl restart burrowee-gateway.service' failed — the newly" >&2
                echo "error: installed binaries are on disk, but the daemon still running is the" >&2
                echo "error: OLD one. 'burrowee gateway doctor' reports installed/running drift" >&2
                echo "error: until it is restarted, and a unit rewritten to a new ExecStart has" >&2
                echo "error: not taken effect." >&2
                echo "hint: restart it by hand: sudo systemctl restart burrowee-gateway.service" >&2
            fi

            run_root systemctl enable --now burrowee-gateway-updater.service 2>/dev/null || true
            # A reinstall over an already-running (possibly stale) updater must advance
            # it to the freshly-installed binary — `enable --now` no-ops a running unit,
            # so restart it explicitly. Otherwise the stale updater keeps running old
            # code and future pushes deadlock. (load_units is never called on the
            # updater's own push path — BURROWEE_UPDATE renders units without loading
            # them — so this can never self-kill. The Darwin branch above already
            # advances the updater via its bootout+bootstrap.)
            run_root systemctl restart burrowee-gateway-updater.service 2>/dev/null || true
        fi
        ;;
    esac
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
# $BIN_DIR placement: one elevation decision, all-or-nothing.
#
# Mirrors gateway/update.sh's PLACE_ELEVATED (see that script's header for the
# full field history). $BIN_DIR was always writable under the old default
# ($HOME/.local/bin); it is root-owned under the new one (/usr/local/bin), so
# placing straight onto the final names with a bare `install` would die on the
# first binary for anyone who is not already root. The elevation is decided
# ONCE per mode, by a real create rather than assumed, so an explicit PREFIX
# into a writable tree never pays for a sudo call it does not need — and every
# write of one placement goes through the SAME decision, so a set can never end
# up half-elevated.
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
        echo "install: this install's PREFIX is root-owned; re-run as root, grant this user" >&2
        echo "install: sudo, or set PREFIX to an unprivileged location for a developer install." >&2
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
# Mode dispatch.
# ---------------------------------------------------------------------------

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
    # AFTER load_units, never before — see remove_stale_libexec_tree's own
    # comment. This is the mode `burrowee gateway service install` runs, and it
    # is the one that converges a host still carrying the pre-collapse tree: by
    # this point the unit has been rewritten to name $BIN_DIR AND reloaded into
    # the live supervisor, so the old tree is genuinely unreferenced.
    remove_stale_libexec_tree
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
    exit 0
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
        echo "update: this install's PREFIX is root-owned; re-run as root, or grant this" >&2
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
    # $BIN_DIR may be root-owned (the default) or per-user (an explicit
    # PREFIX) — decide elevation once, the same way every other placement in
    # this script does, rather than assuming either.
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

    # The pre-collapse tree too, or an uninstall leaves a root-owned tree behind
    # for nothing to ever clean up again. Order does not matter here the way it
    # does for a converging install: the units are about to be torn down below,
    # so there is no live supervisor reference left to race.
    remove_stale_libexec_tree

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
assert_can_migrate "./burrowee-gateway-cli"

place_all_bins

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "note: $BIN_DIR is not on PATH — add: export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

"$BIN_DIR/burrowee" --version 2>/dev/null || true

# Write and load both SYSTEM service units (single-slot consent first, then
# migrate any legacy per-user units out of the way). The state migration runs
# before render_units, not between it and load_units: a failed migration exits
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
load_units
# AFTER load_units, never before — see remove_stale_libexec_tree's own comment:
# the unit must already be rewritten to name $BIN_DIR AND reloaded into the
# live supervisor before the pre-collapse tree it used to name can safely go.
remove_stale_libexec_tree
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
elif { exec 3<>/dev/tty; } 2>/dev/null; then
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

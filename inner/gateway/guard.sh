#!/bin/sh
# inner/gateway/guard.sh — the install guard.
#
#     guard.sh <transaction-dir>
#
# It is handed to launchd/systemd by install.sh, NOT forked from the operator's
# shell, so it has no controlling terminal and no ancestry in the session that
# is about to die. That is the entire point: on a gateway the operator reaches
# the host THROUGH the daemon this script restarts, so the restart severs the
# session, and anything still running in that session dies with it.
#
# It owns the outcome of the whole install, not just the restart, because the
# restart is not the only thing that stops the daemon: gateway's own migration
# ladder (migrations/run.sh, stop_gateway) stops it too, earlier, to copy state
# at rest. A guard armed only for the restart would watch the wrong line.
#
# AND IT OWNS EVERY ABORT, not just the ones that reach the handoff. The
# installer's own foreground abort paths — a declined consent prompt, a failed
# Phase 2 check — do NOT restore or mark the transaction terminal themselves.
# They print and exit, and this script's installer-died branch does the work,
# because a foreground `snapshot_restore` only COPIES FILES: on a host whose
# migration already stopped (and on Darwin unloaded) the daemon, "restored the
# previous install" without a restart is the reported stranding through a
# different door. Only rollback() below restores AND restarts AND verifies.
#
# BEING DETACHED IS ALSO WHAT LETS IT RELOAD A CHANGED UNIT. `bootstrap` on an
# already-loaded label exits 5 and `kickstart -k` restarts the in-memory job:
# neither re-reads the plist, so with the installer's bootout gone a rendered
# change to ExecStart or KeepAlive took effect only at the next reboot. The
# stranding was never the bootout itself — it was a bootout whose bootstrap sat
# in a process the bootout could kill — so this script may do it, gated on
# place_unit having recorded that the file actually changed. See
# restart_service.
#
# IT ALSO REMOVES ITS OWN PLIST on every exit path (remove_guard_unit): the
# guard job is RunAtLoad, and one left on disk re-runs against a finished (or
# worse, a half-finished) transaction at every boot.
#
# EXIT CONTRACT: 0 ok · 1 rolled-back or aborted · 2 failed.
#
# `aborted` is the fourth phase and the youngest: an install that was undone on
# a host that had NOTHING to undo to. See rollback's snapshot_has_binaries
# branch — it exits 1 like `rolled-back` (the new build is not serving either
# way) but says the opposite thing about the host, and an operator reading
# guard-status must not be told a previous build was restored when there was
# never a previous build.
#
# AND IT IS ONLY HONEST BEFORE A RESTART. "Nothing was started; the host is as
# it was found" is a claim about this guard's own actions, and rollback() is
# reached from four places — three of them before any restart (an empty binary
# version stamp, the installer dying, the deadline), one of them AFTER
# restart_service has already bootstrapped, enabled and kickstarted the new
# unit (do_restart's verify_serving failure). On a fresh host that took the
# normal accepted-consent path and whose new build simply never reported its
# version, that fourth path lands in the same empty-snapshot arm — and there
# the sentence is false twice over: the new unit IS loaded, and it is probably
# crash-looping. RESTART_ATTEMPTED below is what tells the two apart, and that
# path reports `failed` ("this host needs hands"), which is what it is: the
# host is not serving, and nothing could be put back because there was nothing
# to put back. No new phase token for it — `failed` already means exactly that
# and the gateway cli already renders it.
set -eu


TXN="${1:?usage: guard.sh <transaction-dir>}"

LAUNCHCTL="${GUARD_LAUNCHCTL:-launchctl}"
SYSTEMCTL="${GUARD_SYSTEMCTL:-systemctl}"
UNAME="${GUARD_UNAME:-$(uname -s)}"
BIN_DIR="${BURROWEE_BIN_DIR:-/usr/local/bin}"
SYS_DATA_DIR="${BURROWEE_SYSTEM_DATA_DIR:-/usr/local/var/burrowee/gateway}"
SYS_CONFIG_DIR="${BURROWEE_SYSTEM_CONFIG_DIR:-/usr/local/etc/burrowee/gateway}"

# The unit directories, resolved ONCE and by the same env-default spellings
# install.sh uses for its own LAUNCHD_DIR/SYSTEMD_DIR (install.sh:204-206).
# They used to be open-coded inline in three places here under a different
# variable name (_ud) than install.sh's snapshot_restore uses (_unit_dir), so
# the two functions that restore the same files agreed only by coincidence of
# defaults. One name per side, spelled identically, is the cheapest way to
# make a future retune of either seam visibly break both.
LAUNCHD_DIR="${BURROWEE_LAUNCHD_DIR:-/Library/LaunchDaemons}"
SYSTEMD_DIR="${BURROWEE_SYSTEMD_DIR:-/etc/systemd/system}"

# The installer copies state; a generous ceiling so a slow migration is not
# mistaken for a wedged one.
DEADLINE="${GUARD_DEADLINE:-900}"
VERIFY_CEILING="${GUARD_VERIFY_CEILING:-60}"
VERIFY_INTERVAL="${GUARD_VERIFY_INTERVAL:-2}"
# A floor of 1, because VERIFY_INTERVAL is what the verify loop's counter
# advances by: at 0 the counter never moves and `while [ "$_waited" -lt
# "$VERIFY_CEILING" ]` is an infinite `sleep 0` spin that no ceiling ever ends
# — a wedged guard, not a fast one. The seam exists for a suite that wants a
# SHORT interval, and 1 is the shortest one that terminates.
[ "$VERIFY_INTERVAL" -gt 0 ] 2>/dev/null || VERIFY_INTERVAL=1

LABEL=com.burrowee.gateway
UNIT=burrowee-gateway.service
GUARD_LABEL=com.burrowee.gateway.guard

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >> "$TXN/guard.log"; }
phase() { printf '%s\n' "$1" > "$TXN/.phase.tmp" && mv -f "$TXN/.phase.tmp" "$TXN/phase"; }
now() { date -u +%s; }

# unit_dir — the platform's system unit directory. install.sh's
# snapshot_restore holds the identical case; see the LAUNCHD_DIR note above.
unit_dir() {
    case "$UNAME" in
    Darwin) printf '%s\n' "$LAUNCHD_DIR" ;;
    Linux)  printf '%s\n' "$SYSTEMD_DIR" ;;
    *)      printf '\n' ;;
    esac
}

# ---------------------------------------------------------------------------
# remove_guard_unit — the transient LaunchDaemon removes its OWN plist, on
# EVERY exit path, which is what the design has always claimed and what the
# first cut did not do.
#
# A plist left in /Library/LaunchDaemons is RunAtLoad, so launchd re-execs
# `gateway-guard <that transaction dir>` at every boot, forever. A terminal
# transaction exits harmlessly at the watch loop's "already terminal" arm — but
# a NON-terminal one (power lost mid-install) hands the boot-time guard a stale
# installer.pid that is certainly dead after a reboot, and it rolls the host
# back: a weeks-old config/ and data/ (gateway.db included) copied over live
# state, by a process nobody asked for, on a host that had recovered by itself.
#
# An EXIT trap and not a call before each `exit`: this script runs under
# `set -eu`, so an unexpected non-zero anywhere leaves through a path no
# explicit call sits on, and that is exactly the run whose plist must not
# survive.
#
# The plist only, never `launchctl bootout` of this very job — that would kill
# the guard inside its own exit trap. Removing the file is enough: launchd
# keeps the (already exiting) job in memory until the next guard_arm boots the
# label out, and with no file on disk there is nothing to load at boot.
#
# Linux needs nothing: guard_arm uses `systemd-run --collect`, which reaps the
# transient unit itself.
# ---------------------------------------------------------------------------
remove_guard_unit() {
    case "$UNAME" in
    Darwin)
        if [ -f "$LAUNCHD_DIR/$GUARD_LABEL.plist" ]; then
            rm -f "$LAUNCHD_DIR/$GUARD_LABEL.plist" 2>/dev/null \
                || log "could not remove $LAUNCHD_DIR/$GUARD_LABEL.plist — it will re-run at boot"
        fi
        ;;
    esac
}
trap remove_guard_unit EXIT

# THE FIRST TWO STATEMENTS, and install.sh depends on it. `launchctl bootstrap`
# and `systemd-run` exiting 0 mean the job was LOADED, not that it RAN, so
# guard_arm polls for exactly these two artefacts before it lets the install
# proceed (install.sh's guard_arm, "the arm-proof poll"). A guard that dies on
# exec must not read as a guard that is watching.
printf '%s\n' "$$" > "$TXN/guard.pid"
log "guard armed for $TXN"

# running_version — the version the daemon reports for ITSELF. The same oracle
# the installer's wait uses; there is deliberately no second definition of
# healthy anywhere in this system.
running_version() {
    sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$SYS_DATA_DIR/running.json" 2>/dev/null || true
}

# VERSION_BOUND — the same 2s ceiling install.sh's binary_version_stamp
# applies, decided once here for the same reason it is decided there: this
# probe execs the FRESHLY PLACED, possibly broken serve binary, and an
# unbounded `version` on a binary that hangs hangs the prober. In install.sh
# that wedged the installer; here it is worse — do_restart runs past the watch
# loop, so the deadline that would have rescued a wedged install no longer
# applies, and the guard sits at phase=restarting forever while guard-status
# reports "the guard is still working" about a process that will never move.
#
# Same availability rule as install.sh's: `timeout` (GNU coreutils, on every
# Linux host), `gtimeout` where a macOS host installed coreutils, and no bound
# at all otherwise. A stock macOS host is still unbounded — a stated gap
# inherited verbatim, not a new one.
VERSION_BOUND=""
if command -v timeout >/dev/null 2>&1; then
    VERSION_BOUND="timeout 2"
elif command -v gtimeout >/dev/null 2>&1; then
    VERSION_BOUND="gtimeout 2"
fi

# running_pid — the pid the daemon recorded for itself in running.json, or "".
running_pid() {
    sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
        "$SYS_DATA_DIR/running.json" 2>/dev/null || true
}

# supervisor_holds_serve_job — does the supervisor THIS GUARD ALREADY DRIVES
# still hold the serve job?
#
# The deciding voice in running_alive below, and the only one of its three
# conjuncts that reads live state rather than a file the daemon left behind.
# launchd and systemd are the authorities on whether the job exists; this asks
# the same binary restart_service would call, through the same GUARD_LAUNCHCTL
# / GUARD_SYSTEMCTL seam, so there is no second notion of "the supervisor" in
# this script.
#
# Darwin: `launchctl print system/<label>` exits non-zero when the label is not
# loaded in the system domain — which is EXACTLY the state the migration's
# bootout leaves behind, the one this whole design exists to notice. It answers
# "unloaded" directly, without parsing launchd's output format (which differs
# by macOS release and is not a contract).
#
# Linux: `systemctl is-active` exits 0 only for a unit systemd considers
# active; inactive, failed, activating and unknown-unit all exit non-zero. The
# EXIT STATUS, not the word on stdout: the status is the documented interface
# and survives a locale or a version that words the state differently.
#
# ANY OTHER ANSWER IS "RESTART". A missing supervisor binary, a supervisor that
# errors, an unrecognised $UNAME — all return 1 here, and all mean the guard
# bounces the service. That direction is chosen deliberately: a false "alive"
# strands the host with a dead daemon and no one watching, a false "dead" costs
# one bounced connection.
supervisor_holds_serve_job() {
    case "$UNAME" in
    Darwin) "$LAUNCHCTL" print "system/$LABEL"   >/dev/null 2>&1 ;;
    Linux)  "$SYSTEMCTL" is-active "$UNIT"       >/dev/null 2>&1 ;;
    *)      return 1 ;;
    esac
}

# running_alive <want> — the daemon is REALLY up and REALLY serving <want>.
#
# THREE conjuncts, and none of them is enough alone. running.json survives the
# daemon that wrote it, so the version alone says only "the last daemon to
# start reported this" — true of a host whose serve label was booted out
# minutes ago by the migration. The pid alone says only "something with that
# number exists". Together they are strong but not sound: an install window is
# minutes long, and a pid freed by the migration's stop can be handed to any
# process started since (macOS wraps at 99998; a busy Linux host commonly at
# 32768). The version still matches, because it is the same stale file
# snapshot_take read — so pid+version alone can conclude "already serving"
# about a host that is DOWN, which is the reported stranding restored as an
# optimisation.
#
# The supervisor closes it: core's runtime_version.WriteRunning records
# {"version","pid","started_at"} at serve start, so a live pid beside a
# matching version identifies the daemon, and launchd/systemd still holding the
# job is what says that daemon is the one running now. Cheap, because this
# branch only ever decides whether to SKIP a restart — the expensive direction
# is the safe one.
running_alive() {
    _ra_pid="$(running_pid)"
    [ -n "$_ra_pid" ] || return 1
    [ "$(running_version)" = "$1" ] || return 1
    kill -0 "$_ra_pid" 2>/dev/null || return 1
    supervisor_holds_serve_job
}

# binary_version — the version the freshly placed binary reports for ITSELF.
#
# DELIBERATELY NOT install.sh's binary_version_stamp, and not a candidate for
# being merged with it. That helper is byte-identical with edge's (pinned by
# tools/install-waits-for-daemon.test.sh) and filters tokens through
# `grep -E '^v?[0-9]+(\.[0-9]+){0,5}(\.[0-9a-f]+)?$'`, which REJECTS a
# pre-release token: against core runtime_version.Report's two-line output the
# real stamp `v0.3.1.beta.2026.08.31.62a6f215` fails that pattern and the
# helper falls through to the SECOND line — the RUNNING daemon's version — so
# on a beta build it answers the question this guard is not asking. The `sed`
# below takes the first version-shaped token off the FIRST line and keeps the
# beta segment, which is the string running.json will actually carry.
#
# (The shared helper's beta blindness is pre-existing and out of scope here.
# It is written down at both sites so the next reader who notices the
# duplication learns that unifying them would silently break this one.)
#
# This block sat ABOVE running_pid for two revisions — a header describing a
# function eighty lines further down, with the function it actually stood over
# carrying its own one-liner underneath it. Moved to where it belongs; nothing
# about either function changed.
binary_version() {

    # shellcheck disable=SC2086  # $VERSION_BOUND is a command PREFIX and must word-split; empty means no bound.
    BURROWEE_DISPATCHER_VERSION= $VERSION_BOUND "$BIN_DIR/burrowee-gateway" version 2>/dev/null |
        sed -n 's/.*\(v[0-9][0-9.a-z]*\).*/\1/p' | head -1
}

# serve_unit_file — the SERVE unit's basename on this platform, resolved once.
# Both unit_body_changed and snapshot_has_serve_unit ask the same question
# about the same file, and spelling it twice is how the two would come to
# disagree about which file they mean.
serve_unit_file() {
    case "$UNAME" in
    Darwin) printf '%s\n' "$LABEL.plist" ;;
    Linux)  printf '%s\n' "$UNIT" ;;
    *)      printf '\n' ;;
    esac
}

# unit_body_changed — did THIS install rewrite the serve unit's file?
#
# install.sh's place_unit appends the basename of every unit whose content it
# actually replaced to $TXN/units-changed (it writes nothing when the rendered
# file is byte-identical to the one already there). That marker is the whole
# signal; an absent file means nothing changed.
unit_body_changed() {
    [ -f "$TXN/units-changed" ] || return 1
    _ubc_u="$(serve_unit_file)"
    [ -n "$_ubc_u" ] || return 1
    grep -q "^$_ubc_u\$" "$TXN/units-changed"
}

# snapshot_has_serve_unit <snapshot-dir> — did snapshot_take capture the serve
# unit's own file? snapshot_take copies only units that were already on disk
# ([ -f ] per name), so on a host that has never had a gateway this is false
# and the file now on disk is the one THIS run rendered.
snapshot_has_serve_unit() {
    _shsu_u="$(serve_unit_file)"
    [ -n "$_shsu_u" ] || return 1
    [ -f "$1/units/$_shsu_u" ]
}

# restart_service — kickstart -k / systemctl restart. NEVER bootout FROM THE
# INSTALLER: an unloaded job is supervised by nothing, so a shell that dies
# between a bootout and its bootstrap strands exactly the state this script
# exists to prevent — and on a gateway the bootout is what kills that shell.
#
# THE UNIT BODY IS THE ONE EXCEPTION, and it is why this function takes an
# argument. `bootstrap` on an already-loaded label exits 5 and does nothing;
# `kickstart -k` restarts the job launchd already holds IN MEMORY. Neither
# re-reads the plist. So with the installer's bootout gone, a rendered change
# to ExecStart, EnvironmentVariables, KeepAlive or StandardOutPath took effect
# only at the next reboot — "files converged, process still stale", the exact
# class this codebase has been burned by before. Linux never had the problem:
# `daemon-reload` + `restart` re-reads the unit by construction.
#
# Doing it HERE is what makes it safe. The stranding was never the bootout
# itself, it was a bootout whose bootstrap sat in a process the bootout could
# kill. This guard is a child of launchd, has no controlling terminal, and is
# not in the operator's session or process group (guard_arm's header): the
# disconnect that killed the installer cannot reach it, so the bootout and the
# bootstrap that follows are two statements in a process nothing is severing.
# The window is bounded by this process being SIGKILLed, which would break the
# rollback path too — and a plist left on disk is still loaded at the next
# boot by launchd, so even that ends with a supervised job.
#
# tools/install-no-bootout.test.sh pins the INSTALLER; this file is
# deliberately outside its scope, and the guard's own bootout below is
# conditional on the file having actually changed.
restart_service() {
    _reload="${1:-}"
    case "$UNAME" in
    Darwin)
        if [ "$_reload" = reload ]; then
            log "the serve unit's body changed — booting the label out so launchd re-reads the plist"
            "$LAUNCHCTL" bootout "system/$LABEL" 2>/dev/null || true
        fi
        "$LAUNCHCTL" bootstrap system "$LAUNCHD_DIR/$LABEL.plist" 2>/dev/null || true
        "$LAUNCHCTL" enable "system/$LABEL" 2>/dev/null || true
        "$LAUNCHCTL" kickstart -k "system/$LABEL" 2>/dev/null || true
        ;;
    Linux)
        "$SYSTEMCTL" daemon-reload 2>/dev/null || true
        "$SYSTEMCTL" enable "$UNIT" 2>/dev/null || true
        "$SYSTEMCTL" restart "$UNIT" 2>/dev/null || true
        ;;
    esac
}

# restart_mode — "reload" when the serve unit's file changed this install,
# empty otherwise. One place decides it, so nothing in do_restart can disagree
# with itself about whether the plist needs re-reading.
restart_mode() {
    if unit_body_changed; then printf 'reload\n'; else printf '\n'; fi
}

# rollback_restart_mode <snapshot-dir> — restart_mode's answer for the UNDO,
# which is not the same question.
#
# do_restart is moving the host FORWARD onto the file this run rendered, so a
# changed serve unit means launchd is holding a stale job and must re-read the
# plist. rollback has just done the opposite: it copied the SNAPSHOT's unit
# back over that file. When the snapshot held one, the content now on disk is
# the content launchd already loaded before this install began — the in-memory
# job and the file agree, and there is nothing to re-read.
#
# The bootout+bootstrap in that case is not merely redundant, it is the harm
# this whole design exists to avoid one door further along: rollback's
# undisturbed-case branch (below) skips the restart entirely when the daemon is
# still serving the snapshot's build, precisely so that DECLINING the consent
# prompt does not drop the connection the decline was protecting — and the
# branch is gated on this mode being empty. A run that merely re-rendered the
# unit template (a new StandardOutPath, say) therefore dropped the operator's
# session on a decline, which is the one answer they gave to say "do not".
#
# Narrow deliberately: when the snapshot has NO serve unit there is nothing to
# have restored, the file on disk is this run's, and a reload is still correct.
rollback_restart_mode() {
    unit_body_changed || { printf '\n'; return 0; }
    if snapshot_has_serve_unit "$1"; then printf '\n'; return 0; fi
    printf 'reload\n'
}

# verify_serving <want> — the daemon reports <want> within the ceiling.
verify_serving() {
    _want="$1"; _waited=0
    while [ "$_waited" -lt "$VERIFY_CEILING" ]; do
        if [ "$(running_version)" = "$_want" ]; then
            log "daemon is serving $_want (after ${_waited}s)"
            return 0
        fi
        sleep "$VERIFY_INTERVAL"
        _waited=$((_waited + VERIFY_INTERVAL))
    done
    log "daemon did not report $_want within ${VERIFY_CEILING}s"
    return 1
}

# ---------------------------------------------------------------------------
# SHARED WITH install.sh, BYTE FOR BYTE, and pinned by
# tools/guard-rollback.test.sh so it cannot drift. install.sh's abort_install
# asks the same question this file's rollback does — "is there a previous
# install behind this snapshot at all" — and answers `aborted` rather than
# `rolled-back` when there is not. See that file's copy for why the duplication
# is deliberate here rather than a shared library.
# ---------------------------------------------------------------------------
# snapshot_has_binaries <snapshot-dir> — did snapshot_take actually capture a
# previous install's binaries, or is this directory the empty shell a fresh
# host produces?
#
# snapshot_take copies only the names that were ALREADY in $BIN_DIR
# (`[ -f "$BIN_DIR/$b" ]`), so on a host that has never had a gateway the
# snapshot's bin/ is created and left empty — a distinction the rest of
# rollback cannot make from the manifest alone, because `running_version` is
# the placeholder `unknown` for BOTH "fresh host" and "the daemon was already
# down".
#
# An `if` inside the loop, not `[ -e … ] && return 0`: an AND-list is the last
# statement of the loop body, so on the final non-matching entry the `for`
# itself returns 1 and `set -e` kills the guard mid-rollback. An `if` with no
# `else` returns 0 whichever way it goes — the same shape, and the same
# reason, as apply_retention's prune body below.
snapshot_has_binaries() {
    [ -d "$1/bin" ] || return 1
    for _shb in "$1/bin"/*; do
        if [ -e "$_shb" ]; then return 0; fi
    done
    return 1
}

# RESTART_ATTEMPTED — has this guard already driven the supervisor at the SERVE
# label this run? Set by do_restart immediately before restart_service, and
# never cleared.
#
# It exists for one sentence: the empty-snapshot arm of rollback() below tells
# the operator "nothing was started; the host is as it was found". That is a
# claim about what THIS PROCESS did, and rollback() has four callers — three
# reached before any restart, one reached after do_restart has already
# bootstrapped, enabled and kickstarted the new unit. Only the phase file
# distinguishes them otherwise, and it does not: do_restart writes `restarting`
# before it reads the binary's version stamp, so it reads `restarting` on the
# path where nothing has been started as well as on the path where something
# has. A flag set exactly where the restart happens cannot be wrong about it.
RESTART_ATTEMPTED=0

# rollback — put the last working point back AND prove it is serving.
#
# EVERY restore step is failure-TOLERANT and logs its own failure, because a
# partial restore that gets the binaries back is strictly better than one that
# stops at the first error. The config and data trees used to be the two
# exceptions: `[ -d … ] && cp -Rp …` makes the cp the last member of an
# AND-list, so a failing cp aborted the whole guard under `set -eu` — leaving
# phase=rolling-back on disk forever, which guard-status reports as "the guard
# is still working" about a process that no longer exists. install.sh's
# snapshot_restore already collects a return code and keeps going, and the bin
# and unit loops eight lines above already used `|| log`; this is that one
# treatment, applied to all four.
rollback() {
    phase rolling-back
    log "restoring the snapshot"
    _snap="$TXN/snapshot"
    _want="$(sed -n 's/^running_version=//p' "$TXN/manifest" 2>/dev/null || true)"
    # snapshot_take records "unknown" when the host had no running.json to read
    # — a fresh host, or one whose daemon was already down when the install
    # began. It is a placeholder, never a version: comparing against it burns
    # the whole verify ceiling and then reports `failed` ("this host needs
    # hands") about a rollback that may have completed perfectly. Treated as
    # "no stamp to verify against" below.
    if [ "$_want" = unknown ]; then _want=""; fi

    if [ -d "$_snap/bin" ]; then
        for _b in "$_snap/bin"/*; do
            [ -e "$_b" ] || continue
            cp -p "$_b" "$BIN_DIR/${_b##*/}" || log "could not restore ${_b##*/}"
        done
    fi
    _ud="$(unit_dir)"
    if [ -n "$_ud" ] && [ -d "$_snap/units" ]; then
        for _u in "$_snap/units"/*; do
            [ -e "$_u" ] || continue
            cp -p "$_u" "$_ud/${_u##*/}" || log "could not restore ${_u##*/}"
        done
    fi
    if [ -d "$_snap/config" ]; then
        cp -Rp "$_snap/config/." "$SYS_CONFIG_DIR/" || log "could not restore the config tree"
    fi
    if [ -d "$_snap/data" ]; then
        cp -Rp "$_snap/data/." "$SYS_DATA_DIR/" || log "could not restore the state tree"
    fi

    # NOTHING TO RESTORE, SO NOTHING TO START — and this branch is a
    # correctness fix, not an optimisation.
    #
    # `unknown` in the manifest means snapshot_take found no running.json.
    # That is a fresh host as often as it is a stopped daemon, and on a fresh
    # host the snapshot's bin/ is empty too: there is no previous binary, no
    # previous plist, nothing this function can put back. Falling through to
    # restart_service there does not restore anything — it bootstraps the unit
    # THIS RUN just rendered, against the binary THIS RUN just placed, and on
    # Linux `enable`s it as well. So:
    #
    #   * an operator who DECLINED the consent prompt on a fresh interactive
    #     install got the gateway installed, started and enabled anyway — the
    #     exact inverse of the answer they gave;
    #   * a Phase 2 verification failure started a build whose own placement
    #     or unit check had just failed;
    #   * and both then reported `rolled-back`, which guard-status renders as
    #     "the previous one was restored and is serving" about a host that has
    #     no previous one and is serving nothing.
    #
    # `failed` would be no better: that phase means "the rollback did not come
    # up either — this host needs hands", and a virgin host with no gateway
    # running needs no hands at all. It is in exactly the state it was found
    # in, which is the thing the operator has to be told. Hence a phase of its
    # own.
    #
    # The binaries this run placed are left on disk. Removing them is not an
    # undo this guard can make safely (it does not know which of them the host
    # already had under another install), and a binary nothing supervises is
    # inert — the stranding this whole design exists to prevent is a DAEMON
    # that is down, not a file that is present.
    #
    # ONE OF THE FOUR CALLERS CANNOT SAY THAT, and the split below is what the
    # `aborted` wording costs elsewhere. do_restart reaches rollback a SECOND
    # time, after restart_service has already bootstrapped, enabled and
    # kickstarted the new unit and verify_serving then timed out. A fresh host
    # that took the normal accepted-consent path — install, handoff, restart,
    # and a build that never reports its version inside the ceiling — arrives
    # here with an empty $_want (no previous running.json) and an empty
    # snapshot (nothing was ever installed), so it lands in exactly this arm.
    # Telling that operator "nothing was started; the host is as it was found"
    # is false in both halves: the new unit is loaded and, given it never
    # reported a version, is most likely crash-looping under its supervisor.
    #
    # `failed` is the honest verdict there — "the host is not serving and the
    # guard could not get it serving; this needs hands" — and it is the phase
    # that already carries exit 2. Nothing was restored, because there was
    # nothing to restore; the log line says so rather than implying a previous
    # build was tried and failed.
    if [ -z "$_want" ] && ! snapshot_has_binaries "$_snap"; then
        if [ "$RESTART_ATTEMPTED" = 1 ]; then
            phase failed
            log "FAILED — the new build was started and never reported its version; the snapshot holds no previous install, so nothing was restored and nothing is serving. This host needs hands."
            exit 2
        fi
        phase aborted
        log "ABORTED — the snapshot holds no previous install to restore, so nothing was started; the host is as it was found (no gateway running)"
        exit 1
    fi

    _mode="$(rollback_restart_mode "$_snap")"

    # THE UNDISTURBED CASE, and the reason the installer's foreground abort
    # paths can safely hand their work here. When the operator declines the
    # consent prompt on a host whose daemon was never stopped, the daemon still
    # running IS the snapshot's build — restoring the files is the whole of the
    # undo, and bouncing the service would drop exactly the connection the
    # decline was protecting. Skipped when the unit body changed too: a restored
    # plist that launchd has not re-read is not a restored host.
    #
    # running_alive, NOT running_version, and the difference is the whole
    # correctness of this branch. running.json is written by the daemon at
    # START and is never removed when it stops, so on the case that matters —
    # a migration that booted the label out — the file still names the old
    # version about a process that is gone. Reading the version alone would
    # conclude "already serving" about a DOWN daemon and skip the restart,
    # which is the stranding this design removes, reintroduced as an
    # optimisation. The pid in that same file narrows it; the supervisor's own
    # answer (running_alive's third conjunct) is what decides it, because a pid
    # freed minutes ago can already belong to something else.
    if [ -z "$_mode" ] && [ -n "$_want" ] && running_alive "$_want"; then

        phase rolled-back
        log "ROLLED BACK — $_want was still serving throughout; files restored, nothing restarted"
        exit 1
    fi

    restart_service "$_mode"
    if [ -z "$_want" ]; then
        # No stamp to verify against (see the "unknown" note above). The
        # restore ran and the service was restarted; claiming `failed` here
        # would send an operator to a host that needs nothing, and claiming a
        # VERIFIED rollback would be a lie. Say which it is, in the log the
        # operator reads.
        phase rolled-back
        log "ROLLED BACK — the snapshot recorded no running version, so the restore could not be verified against one"
        exit 1
    fi
    if verify_serving "$_want"; then
        phase rolled-back
        log "ROLLED BACK — $_want is serving again; the new build was discarded"
        exit 1
    fi
    phase failed
    log "FAILED — the rollback did not come up either; this host needs hands"
    exit 2
}

# sweep_stale_bins_via_kept_installer — run the installer's own
# sweep_stale_user_bins by sourcing the ROOT-SECURE copy at
# $BIN_DIR/install.sh — the one ensure_root_exec_surface places (and
# verify_root_exec_surface proves root-owned and non-root-unwritable all the
# way to /) on every install, well before this guard's post-success work can
# ever run.
#
# NEVER the per-user copy at $GW_HOME (keep_installer_copy): this guard
# already runs as root, and $GW_HOME resolves from the INVOKING OPERATOR's
# $HOME — writable by that operator, or by anything running as them, at any
# time after the install finishes. Sourcing that path as root turns
# "compromise one non-root account that has ever run a gateway install" into
# unattended root code execution on the next successful restart. This file
# must never reference $GW_HOME or a gw_home= manifest field for that reason
# — see install.sh's own header note beside keep_installer_copy: "root never
# runs that one."
#
# Deliberately NOT `burrowee-gateway-cli service install`: that re-enters
# install.sh in BURROWEE_UNITS_ONLY mode, which arms a SECOND guard inside
# this one's own success path. Sourcing the root-secure copy reaches the one
# function this step needs without re-running any of the rest of it.
#
# Run in a subshell (`sh -c`), never dot-sourced into this shell directly:
# install.sh defines BIN_DIR, SYS_DATA_DIR and other names this script also
# uses, and dot-sourcing it here would overwrite them in place. $0 is set to
# the installer's own path via the trailing argument — sh has no other
# portable way to steer it — so install.sh's own `$(dirname "$0")/migrations`
# resolution (stale_sweep_lib) finds the migrations/ copy
# ensure_root_exec_surface keeps right beside it, also under $BIN_DIR.
#
# Must run only AFTER a verified restart — see this file's header and
# sweep_stale_user_bins' own comment in install.sh: it deletes per-user
# binaries, and until the daemon has actually advanced onto the loaded units,
# a still-running per-user process may still name one.
#
# A missing $BIN_DIR/install.sh (a pre-Task-10 host converged from an older
# release, say) is a logged no-op, never a fallback to a less-secure copy:
# skipping housekeeping is a cosmetic loss, sourcing a user-writable file as
# root is not.
sweep_stale_bins_via_kept_installer() {
    if [ ! -f "$BIN_DIR/install.sh" ]; then
        log "no root-secure installer at $BIN_DIR/install.sh — skipping the stale-bin sweep"
        return 0
    fi
    if BURROWEE_SOURCE_ONLY=1 sh -c '. "$0"; sweep_stale_user_bins' "$BIN_DIR/install.sh" \
        >> "$TXN/guard.log" 2>&1
    then
        log "stale-bin sweep ran via $BIN_DIR/install.sh"
    else
        log "stale-bin sweep failed (via $BIN_DIR/install.sh) — continuing"
    fi
}

# advance_updater — start (or restart) the updater unit. load_units used to do
# this in the foreground; Task 7 removed load_units from the fresh-install
# path entirely, which left the updater unit RENDERED but never started on a
# fresh install. This is what restores it, after the serve daemon itself is
# already proven up.
#
# Safe to bootout on Darwin, unlike the serve label: nothing routes through
# the updater, so a guard killed mid-bootout strands nothing an operator needs
# to reach the host.
advance_updater() {
    case "$UNAME" in
    Darwin)
        "$LAUNCHCTL" bootout "system/$LABEL.updater" 2>/dev/null || true
        "$LAUNCHCTL" bootstrap system "$LAUNCHD_DIR/$LABEL.updater.plist" 2>/dev/null || true

        "$LAUNCHCTL" enable "system/$LABEL.updater" 2>/dev/null || true
        "$LAUNCHCTL" kickstart -k "system/$LABEL.updater" 2>/dev/null || true
        ;;
    Linux)
        "$SYSTEMCTL" enable --now burrowee-gateway-updater.service 2>/dev/null || true
        "$SYSTEMCTL" restart burrowee-gateway-updater.service 2>/dev/null || true
        ;;
    esac
    log "updater advanced"
}

# apply_retention — keep this transaction and the two before it. A snapshot is
# a full copy of the state tree, so an unbounded ring of them is an unbounded
# disk cost on a host nobody is watching. Transaction directories are named by
# a UTC timestamp (txn_begin's TXN_STAMP), which sorts lexically, so `sort`
# orders them chronologically with no extra bookkeeping.
#
# Deliberately not `head -n -3`: that negative-count form is a GNU extension
# with no guaranteed BSD equivalent, and this script ships to real Darwin
# hosts (the `head` on the guard's own platform, not just the suite's CI
# box). Counted and sliced by hand instead, entirely in POSIX sh.
#
# THE PRUNE BODY IS AN `if`, NOT AN AND-LIST, and that is not style. The
# previous shape ended each iteration with
# `[ "$_i" -le "$_drop" ] && [ -n "$_old" ] && rm -rf …`. On the LAST
# iteration the counter guard is false, so the AND-list — and with it the
# `while`, and with it the whole pipeline — returns 1. A pipeline's failure is
# not suppressed by the AND-lists INSIDE it, so `set -eu` killed the guard
# right here, from the fourth transaction on: the `log` below never ran, the
# caller died, do_restart never reached its `exit 0`, and the guard left with
# status 1 — which its own contract defines as "rolled-back", on a host that
# had just been verified serving the new build. The prune happened; the exit
# contract did not. An `if` with no `else` returns 0 whichever way it goes.
apply_retention() {
    _base="$SYS_DATA_DIR/install"
    [ -d "$_base" ] || return 0
    _total="$(ls -1 "$_base" 2>/dev/null | wc -l | tr -d ' ')"
    _drop=$((_total - 3))
    if [ "$_drop" -le 0 ]; then
        log "snapshot retention: $_total kept, nothing to prune"
        return 0
    fi
    _i=0
    ls -1 "$_base" 2>/dev/null | sort | while read -r _old; do
        _i=$((_i + 1))
        if [ "$_i" -le "$_drop" ] && [ -n "$_old" ]; then
            rm -rf "$_base/$_old" || log "could not prune $_old"
        fi
    done
    log "snapshot retention applied ($_drop pruned, 3 kept)"
}

do_restart() {
    phase restarting
    _want="$(binary_version)"
    if [ -z "$_want" ]; then
        log "could not read the new binary's version stamp — treating as a failed restart"
        rollback
    fi
    log "restarting $LABEL, expecting $_want"
    # BEFORE the call, never after: rollback() reads this to decide whether
    # "nothing was started" is a true sentence, and a restart_service that
    # drove the supervisor and then died would leave the flag clear and the
    # claim false — the exact failure the flag exists to close.
    RESTART_ATTEMPTED=1
    restart_service "$(restart_mode)"
    if verify_serving "$_want"; then

        # WRITTEN HERE AND NOT AFTER THE HOUSEKEEPING BELOW, deliberately, and
        # the known cost is stated rather than traded away. `ok` means
        # "verified serving", which is true at this line; moving it past the
        # sweep would leave a guard killed mid-housekeeping recorded at
        # `restarting`, and a guard relaunched against that transaction rolls
        # a HEALTHY host back.
        #
        # The cost is a window: guard_refuse_concurrent skips terminal phases,
        # so a second install started in the seconds below arms its own guard,
        # and on Darwin boots this label out mid-sweep. Nothing is stranded —
        # the daemon is up and verified, and the second install's own guard
        # runs the same three steps on its own success — so the fix is not
        # worth its price. Every discriminator that would close it (a
        # completion marker, or refusing on a live pid regardless of phase)
        # widens the recycled-pid hazard guard_refuse_concurrent's own header
        # rejects: an install refused forever by a pid that no longer belongs
        # to any guard is far worse than one skipped sweep.
        phase ok
        log "OK — $_want is serving"

        # Post-success work the installer used to do after load_units, moved
        # here because a severed session skipped all of it.
        sweep_stale_bins_via_kept_installer
        advance_updater
        apply_retention

        exit 0
    fi
    rollback
}

# heartbeat_epoch — the last time the installer said it was alive and working,
# or 0 when it never has.
#
# THE DEADLINE IS NOT A WALL CLOCK ON THE INSTALL, it is a wedge detector, and
# the two stopped being the same thing the moment the install grew blocking
# prompts. The 900s clock starts at Phase 0 and spans BOTH of them (the setup
# blob/PIN prompt and the consent prompt). An operator who walks away at
# `blob>` gets the guard rolling back underneath a live installer, which then
# writes phase=handoff to a guard that has already exited — nothing restarts,
# reattach times out, the install exits 0, and success is reported over a
# partially undone install.
#
# So install.sh refreshes $TXN/heartbeat (a UTC epoch) while it sits on a
# prompt, and the deadline is measured from the LATER of "armed" and that
# stamp. A missing, empty or non-numeric file means no heartbeat has ever been
# written — the pre-existing behaviour exactly — because the installer's
# heartbeat write is deliberately non-prompting and best-effort (see
# install.sh's txn_heartbeat: a heartbeat that can block on a sudo password
# would block on the very thing it measures).
heartbeat_epoch() {
    _hb="$(cat "$TXN/heartbeat" 2>/dev/null || echo 0)"
    case "$_hb" in
        '' | *[!0-9]*) _hb=0 ;;
    esac
    printf '%s\n' "$_hb"
}

# ---- watch ----------------------------------------------------------------
# Three ways out, and every one of them is decided here rather than by whoever
# is still alive:
#   handoff        the installer finished its work and wants the restart
#   installer died the session was severed mid-install — the migration case,
#                  AND every foreground abort (declined consent, a failed
#                  Phase 2 check): those print and exit, and this branch is
#                  what actually restores and restarts. See the file header.
#   deadline       something is wedged; do not hold the host hostage
_ipid="$(cat "$TXN/installer.pid" 2>/dev/null || echo 0)"
_start="$(now)"
while :; do
    _p="$(cat "$TXN/phase" 2>/dev/null || echo unknown)"
    case "$_p" in
        handoff) log "installer handed off"; do_restart ;;
        ok | rolled-back | aborted | failed) log "already terminal ($_p)"; exit 0 ;;
    esac
    if [ "$_ipid" != 0 ] && ! kill -0 "$_ipid" 2>/dev/null; then
        log "installer pid $_ipid exited at phase '$_p' without handing off — rolling back"
        rollback
    fi
    _since="$_start"
    _hb="$(heartbeat_epoch)"
    if [ "$_hb" -gt "$_since" ]; then _since="$_hb"; fi
    if [ $(( $(now) - _since )) -ge "$DEADLINE" ]; then
        log "deadline ${DEADLINE}s exceeded at phase '$_p' (last heartbeat $_hb) — rolling back"
        rollback
    fi
    sleep 1
done


#!/bin/sh
# Burrowee inner installer — edge UPDATER ONLY (POSIX sh, macOS + Linux).
#
# THE UPDATER IS THE ONLY AUTOMATIC DELIVERY CHANNEL, and it has no path back
# to itself. A push update rewrites the serve binary via burrowee-edge-updater
# — never the updater's own binary or unit — and the ONLY thing that places
# the updater's binary + unit is the full component installer (install.sh,
# this file's sibling). So a node whose updater is stale, stopped, or was
# never installed at all cannot be reached by shipping another release: the
# one thing that would fetch it is the thing that is broken. This script is
# the narrow tool that puts the updater back without depending on it —
# `curl -fsSL release.burrowee.com/edge/updater.install.sh | sh`.
#
# *** ENROLLMENT-PRESERVING — CRITICAL ***
# Touches ONLY the updater binary + its unit. NEVER renames, moves, backs up,
# or deletes $HOME/.burrowee/edge, /usr/local/etc/burrowee/edge, or anything
# under either — the full installer's ladder owns that state; this script
# does not resolve a component home at all. Its own migration step (below)
# walks the updater's ladder against a THROWAWAY scratch tree, never the real
# one, so that promise holds structurally rather than by convention.
#
# It also converges a legacy PER-USER updater agent onto the managed system
# unit, by running the same ladder update.sh runs (migrations/updater-ledger).
# Installing the system unit beside a live legacy agent would leave TWO
# updaters running — worse than the stale/missing one this script exists to
# fix — so that convergence rung is not optional here.
#
# Unlike install.sh's default (the updater unit is rendered but left owner
# opt-in), this script ENABLES and STARTS it: an operator running this one
# specifically wants the updater running now.
#
# Env seams (production defaults shown; override in tests to avoid systemd):
#   SYS_BIN_DIR   the one binary destination (default: /usr/local/bin)
#   PREFIX        install prefix — see the guard below. ROOT-ONLY: a PREFIX
#                 naming any OTHER destination is refused, not honored. An
#                 accepted one is UNSET before anything downstream runs.
#   SUDO          elevation command (default: sudo -n — never prompts, so a
#                 daemon-driven run cannot hang on a password)
#   SYSTEMCTL     systemctl binary (default: systemctl)
set -eu

# ── the destination guard — BYTE-IDENTICAL copy of inner/edge/install.sh's
# (task-1-brief decision: copy verbatim, never retype/improve/reflow; a later
# task pins these copies byte-identical across every inner/ script, and a
# drifted copy is exactly what that pin exists to catch). Comments below
# still say "install:" because they are the copied text, unchanged.
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
SYS_BIN_DIR="${SYS_BIN_DIR:-/usr/local/bin}"
# BIN_DIR and SYS_BIN_DIR are ONE destination under two names: the units and the
# test harness spell it SYS_BIN_DIR, the placement/uninstall code below spells it
# BIN_DIR, and since the 0.2.0 collapse they can never differ. Resolved HERE, at
# the top, rather than beside the config home further down — the shared sweep
# library reads $BIN_DIR for the guard that refuses to sweep the install
# destination, and a library sourced before the value was decided would have
# taken the production default while this run installed somewhere else.
BIN_DIR="$SYS_BIN_DIR"

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
        # /usr/local/bin (production truth, and what the suite's static pins
        # check) and the resolved $_true_bin. They differ only when the
        # SYS_BIN_DIR test seam is set, and an operator reading a refusal on a
        # real host must see the real path either way.
        #
        # printf, not echo, on the two lines that interpolate caller-controlled
        # text: a PREFIX containing a backslash escape ('\c' ends echo's output
        # in dash) would otherwise truncate the refusal at the moment it quotes
        # the offending value, hiding the component, the destination and the
        # "nothing has been installed" line all at once.
        printf '%s\n' "install: PREFIX is set to '$PREFIX', but as of edge 0.2.0 this installer" >&2
        echo "install: has one destination: /usr/local/bin, root-owned. The per-user prefix" >&2
        echo "install: flow is gone — edge's service units run as root and name the binaries" >&2
        echo "install: absolutely, and other components resolve /usr/local/bin/burrowee by" >&2
        echo "install: absolute path, so a per-user copy is invisible to both." >&2
        printf '%s\n' "install: (a PREFIX resolving to $_true_bin is honoured; '$_prefix_bin' is not it.)" >&2
        echo "hint: unset PREFIX and re-run; nothing has been installed." >&2
        exit 1
    fi
    unset _prefix_bin _true_bin
fi
# ── end of the byte-identical guard copy ─────────────────────────────────────

SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
SYSTEMD_UPDATER_UNIT="$SYSTEMD_UNIT_DIR/burrowee-edge-updater.service"
LAUNCHD_PLIST_DIR="${LAUNCHD_PLIST_DIR:-/Library/LaunchDaemons}"
LAUNCHD_UPDATER_PLIST="$LAUNCHD_PLIST_DIR/com.burrowee.edge.updater.plist"
LAUNCHD_UPDATER_LABEL="com.burrowee.edge.updater"

SYSTEMCTL="${SYSTEMCTL:-systemctl}"
SUDO="${SUDO:-sudo -n}"

# elevate CMD… — run CMD as root: directly when already root, else through
# $SUDO. Documented as `curl ... | sh` (no sudo prefix) precisely because this
# script self-elevates every privileged step, mirroring updater.update.sh's
# own elevate — the invoking shell is not assumed to already be root.
elevate() {
    if [ "$(id -u)" = 0 ]; then
        "$@"
    else
        $SUDO "$@"
    fi
}

# MIGRATIONS_DIR resolved early (not just beside the ladder invocation below):
# lib_paths.sh's root_home() is the one implementation of the /root vs
# /var/root rule, and the unit render below needs ROOT_HOME before the ladder
# ever runs. The inline fallback is reached only by a bundle carrying no
# migrations/ at all.
MIGRATIONS_DIR=""
if [ -d "$(dirname "$0")/migrations" ]; then
    MIGRATIONS_DIR="$(dirname "$0")/migrations"
fi
if [ -n "$MIGRATIONS_DIR" ] && [ -f "$MIGRATIONS_DIR/lib_paths.sh" ]; then
    # shellcheck source=/dev/null
    . "$MIGRATIONS_DIR/lib_paths.sh"
fi
if command -v root_home >/dev/null 2>&1; then
    ROOT_HOME="$(root_home)"
elif [ "$(uname -s)" = "Darwin" ]; then
    ROOT_HOME="${ROOT_HOME:-$(eval echo ~root)}"
    case "$ROOT_HOME" in /*) ;; *) ROOT_HOME=/var/root ;; esac
else
    ROOT_HOME="${ROOT_HOME:-/root}"
fi

# place_bin SRC DST — install a 0755 binary and strip the macOS quarantine
# xattr. Elevated (see elevate's comment above): unlike updater.update.sh,
# which runs FROM the already-privileged updater daemon, this script is the
# fresh `curl | sh` entrypoint and cannot assume the invoking shell is root.
place_bin() {
    elevate mkdir -p "$(dirname "$2")"
    elevate install -m 0755 "$1" "$2"
    if [ "$(uname -s)" = "Darwin" ]; then
        elevate xattr -d com.apple.quarantine "$2" 2>/dev/null || true
    fi
}

# ── place ONLY the updater binary (fail loudly if missing) ────────────────────
[ -f "./burrowee-edge-updater" ] || {
    echo "updater.install.sh: missing burrowee-edge-updater in release dir" >&2
    exit 1
}
place_bin "./burrowee-edge-updater" "$BIN_DIR/burrowee-edge-updater"
echo "updater.install.sh: placed $BIN_DIR/burrowee-edge-updater"

# ── write the updater unit (system-scope). Rendering ONLY — no load/start
# here; that happens after the ladder below, same reason install.sh keeps
# the "already loaded" bootout+bootstrap dance in one place: a reload before
# the ladder has had a chance to converge a legacy agent would be a second,
# uncoordinated writer of the same unit. ────────────────────────────────────
if [ "$(uname -s)" = "Darwin" ]; then
    _unit_body="$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LAUNCHD_UPDATER_LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN_DIR/burrowee-edge-updater</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>PathState</key><dict><key>$BIN_DIR/burrowee-edge-updater</key><true/></dict></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>EnvironmentVariables</key><dict><key>HOME</key><string>$ROOT_HOME</string></dict>
</dict></plist>
EOF
)"
    elevate mkdir -p "$LAUNCHD_PLIST_DIR"
    printf '%s\n' "$_unit_body" | elevate tee "$LAUNCHD_UPDATER_PLIST" >/dev/null
    elevate chmod 0644 "$LAUNCHD_UPDATER_PLIST"
    echo "updater.install.sh: wrote LaunchDaemon → $LAUNCHD_UPDATER_PLIST"
else
    _unit_body="$(cat <<EOF
[Unit]
Description=burrowee edge updater
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=/root
ExecStart=$BIN_DIR/burrowee-edge-updater run
Restart=always
RestartSec=2
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
)"
    elevate mkdir -p "$SYSTEMD_UNIT_DIR"
    printf '%s\n' "$_unit_body" | elevate tee "$SYSTEMD_UPDATER_UNIT" >/dev/null
    elevate chmod 0644 "$SYSTEMD_UPDATER_UNIT"
    echo "updater.install.sh: wrote systemd unit → $SYSTEMD_UPDATER_UNIT"
fi

# ── THE UPDATER'S OWN LADDER ───────────────────────────────────────────────────
# migrations/updater-ledger, walked by the SAME shared runner (migrations/run.sh)
# update.sh uses, but pointed at a SEPARATE ledger — see
# inner/_shared/migrations/adopt_updater_unit.sh's header for why the serve
# ladder structurally cannot converge a legacy updater agent, and why this
# track is the one place that is allowed to.
#
# *** ENROLLMENT-PRESERVING, EVEN HERE ***. The runner's own bookkeeping — the
# version anchor and the per-item receipts — normally lives INSIDE $COMP_HOME,
# exactly the tree this script's header promises never to touch. So this
# ladder is walked against a THROWAWAY scratch tree, never a real component
# home: adopt_updater_unit.sh is independently idempotent (its own --applies
# probe re-examines the live supervisor state on every run), so losing the
# runner's receipt between runs costs nothing but a cheap re-probe.
#
# A rung returning 3 means it ran nothing and stopped nothing (DEFERRED, not
# failed) — the binary above is already placed and the unit already written;
# only 1 (anything else) means the ladder itself refused or broke, which stops
# this script before the unit is ever loaded.
MIGRATIONS_DIR=""
if [ -d "$(dirname "$0")/migrations" ]; then
	MIGRATIONS_DIR="$(dirname "$0")/migrations"
fi
if [ -n "$MIGRATIONS_DIR" ] && [ -f "$MIGRATIONS_DIR/run.sh" ] && [ -f "$MIGRATIONS_DIR/updater-ledger" ]; then
	_ul_home="$(mktemp -d 2>/dev/null)" || _ul_home=""
	if [ -z "$_ul_home" ]; then
		echo "updater.install.sh: could not create a scratch tree for the updater ladder — skipping it." >&2
	else
		# adopt_updater_unit.sh deliberately restarts the updater's own supervisor,
		# so this process being killed mid-run is EXPECTED, not hypothetical.
		trap 'rm -rf "$_ul_home"' EXIT INT TERM HUP
		set +e
		LEDGER_FILE="$MIGRATIONS_DIR/updater-ledger" \
			COMP_HOME="$_ul_home" \
			COMP_DATA="$_ul_home" \
			BIN_DIR="$BIN_DIR" \
			SUDO="$SUDO" \
			SYSTEMCTL="$SYSTEMCTL" \
			sh "$MIGRATIONS_DIR/run.sh"
		_ul_rc=$?
		set -e
		rm -rf "$_ul_home"
		case "$_ul_rc" in
		0 | 2 | 3) ;;
		*)
			echo "updater.install.sh: the updater's own state migration refused or failed — stopping." >&2
			echo "updater.install.sh: the updater binary is in $BIN_DIR; nothing else has been changed." >&2
			exit 1
			;;
		esac
	fi
fi

# ── start the updater. Unlike install.sh's default (rendered but left owner
# opt-in), this script enables and starts it — an operator running this one
# specifically wants the updater running now. Bootout-then-reload (Darwin) /
# daemon-reload+enable+restart (Linux) mirrors install.sh's own idempotent
# reload of the serve unit, applied here to the updater's. ───────────────────
if [ "$(uname -s)" = "Darwin" ]; then
    elevate launchctl bootout "system/$LAUNCHD_UPDATER_LABEL" 2>/dev/null || true
    elevate launchctl bootstrap system "$LAUNCHD_UPDATER_PLIST"
    elevate launchctl enable "system/$LAUNCHD_UPDATER_LABEL" 2>/dev/null || true
    elevate launchctl kickstart -k "system/$LAUNCHD_UPDATER_LABEL" 2>/dev/null || true
    echo "updater.install.sh: launchd service $LAUNCHD_UPDATER_LABEL enabled + started"
else
    elevate "$SYSTEMCTL" daemon-reload
    elevate "$SYSTEMCTL" enable --now burrowee-edge-updater
    elevate "$SYSTEMCTL" restart burrowee-edge-updater
    echo "updater.install.sh: systemd service burrowee-edge-updater enabled + (re)started"
fi

echo "updater.install.sh: updater install complete."

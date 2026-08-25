#!/usr/bin/env bash
# test-preflight.sh — offline checks for the per-component preflight + its pin.
#
# Deterministic (no host-tool dependence): it does NOT assert which packages
# install (that depends on what's already on the box) — it asserts the per-comp
# nginx gate, the dry-run structure under a faked package manager, the
# SKIP_NGINX knob, and that install.sh's baked @PREFLIGHT_SHA256@ matches the
# generated preflight. Prints `PREFLIGHT-TEST OK` on success.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\n✗ PREFLIGHT-TEST FAILED: %s\n' "$*" >&2; exit 1; }

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else die "no shasum/sha256sum"; fi
}

# ---- work dir + cleanup ------------------------------------------------------
# This script re-renders every bootstrap with the TEST key (section 1), so it
# MUTATES tracked files. It used to restore nothing at all, leaving TEST-keyed
# bootstraps in the working tree for the next `git add` — a published installer
# that verifies against a key nothing we release is signed with, which
# cmd/rkit/pubkey_bake_test.go names as the reason it exists. Stash the pre-test
# bytes and restore THOSE, on any exit; never `git checkout`, which would also
# throw away a contributor's uncommitted work (the pattern
# tools/test-version-floor.sh and tools/test-tag-binding.sh already use).
GENERATED="cli/install.sh gateway/install.sh edge/install.sh agent/install.sh relay/install.sh
cli/upgrade.sh gateway/upgrade.sh edge/upgrade.sh agent/upgrade.sh
cli/preflight.sh gateway/preflight.sh edge/preflight.sh agent/preflight.sh
edge/updater.install.sh gateway/updater.install.sh"

W="$(mktemp -d "${TMPDIR:-/tmp}/test-preflight-XXXXXX")"
mkdir -p "${W}/orig"
for f in ${GENERATED}; do
    [ -f "${REPO_ROOT}/${f}" ] || continue
    mkdir -p "${W}/orig/$(dirname "${f}")"
    cp "${REPO_ROOT}/${f}" "${W}/orig/${f}"
done

SHIM=""
cleanup() {
    for g in ${GENERATED}; do
        if [ -f "${W}/orig/${g}" ]; then cp "${W}/orig/${g}" "${REPO_ROOT}/${g}"; fi
    done
    rm -rf "${W}" ${SHIM:+"${SHIM}"}
}
trap cleanup EXIT INT TERM

# ---- (1) regenerate with the TEST pubkey so preflight.sh files exist --------
say "gen-bootstraps.sh (TEST pubkey)"
BURROWEE_PUBKEY_FILE="${REPO_ROOT}/tools/testkeys/test.pub" sh tools/gen-bootstraps.sh

for f in cli/preflight.sh gateway/preflight.sh edge/preflight.sh agent/preflight.sh; do
    [ -f "${f}" ] || die "expected generated ${f}"
done

# ---- (2) per-comp nginx gate ------------------------------------------------
say "nginx gate: edge=1, cli/gateway/agent=0"
grep -q 'NGINX="1"' edge/preflight.sh    || die "edge/preflight.sh should bake NGINX=\"1\""
grep -q 'NGINX="0"' cli/preflight.sh     || die "cli/preflight.sh should bake NGINX=\"0\""
grep -q 'NGINX="0"' gateway/preflight.sh || die "gateway/preflight.sh should bake NGINX=\"0\""
grep -q 'NGINX="0"' agent/preflight.sh   || die "agent/preflight.sh should bake NGINX=\"0\""

# ---- (3) dry-run structure under a faked apt-get ----------------------------
say "dry-run edge preflight with a faked apt-get"
# NOTE: no second `trap` here. Registering one would REPLACE the restore trap
# above — sh keeps one handler per signal — and that is exactly how the
# TEST-keyed bootstraps used to survive the run. cleanup() removes the shim.
SHIM="$(mktemp -d "${TMPDIR:-/tmp}/pf-shim-XXXXXX")"
printf '#!/bin/sh\necho "fake-apt $*"\n' > "${SHIM}/apt-get"
chmod +x "${SHIM}/apt-get"
out="$(PATH="${SHIM}:${PATH}" BURROWEE_PREFLIGHT_DRY=1 sh edge/preflight.sh 2>&1)" \
    || die "dry-run edge preflight exited non-zero"
printf '%s\n' "${out}" | grep -q 'package manager: apt'        || die "expected apt detection; got:\n${out}"
printf '%s\n' "${out}" | grep -q 'edge front: nginx'             || die "expected nginx group for edge; got:\n${out}"

# ---- (3b) consent: auto-yes runs the canonical apt verbs --------------------
say "nginx consent: BURROWEE_NGINX_INSTALL=1 dry-runs the apt recipe"
out="$(PATH="${SHIM}:${PATH}" BURROWEE_PREFLIGHT_DRY=1 BURROWEE_NGINX_INSTALL=1 sh edge/preflight.sh 2>&1)" \
    || die "auto-yes dry-run exited non-zero"
printf '%s\n' "${out}" | grep -q 'apt-get install -y nginx libnginx-mod-stream' || die "expected apt nginx install verb; got:\n${out}"
printf '%s\n' "${out}" | grep -q 'systemctl enable --now nginx'                 || die "expected systemctl enable verb; got:\n${out}"

# ---- (3c) consent: auto-no prints tips, installs nothing --------------------
say "nginx consent: BURROWEE_NGINX_INSTALL=0 prints tips and no install verb"
out="$(PATH="${SHIM}:${PATH}" BURROWEE_PREFLIGHT_DRY=1 BURROWEE_NGINX_INSTALL=0 sh edge/preflight.sh 2>&1)" \
    || die "auto-no dry-run exited non-zero"
printf '%s\n' "${out}" | grep -q 'Install it yourself'                          || die "expected tips block; got:\n${out}"
printf '%s\n' "${out}" | grep -q 'ask your AI agent'                            || die "expected AI-agent line; got:\n${out}"
printf '%s\n' "${out}" | grep -q 'sudo burrowee edge doctor'                    || die "expected doctor pointer; got:\n${out}"
printf '%s\n' "${out}" | grep -q '\[dry\].*install -y nginx'                    && die "auto-no must not run install verbs; got:\n${out}"

# ---- (3d) consent: no TTY falls back to tips without hanging ----------------
say "nginx consent: no TTY -> tips (must not hang)"
out="$(PATH="${SHIM}:${PATH}" BURROWEE_PREFLIGHT_DRY=1 BURROWEE_PREFLIGHT_NO_TTY=1 sh edge/preflight.sh 2>&1)" \
    || die "no-TTY dry-run exited non-zero"
printf '%s\n' "${out}" | grep -q 'Install it yourself'                          || die "expected tips on no-TTY; got:\n${out}"
printf '%s\n' "${out}" | grep -q '\[dry\].*install -y nginx'                    && die "no-TTY must not install; got:\n${out}"

# mk_pm_shim <pm-binary...> — a curated PATH dir exposing ONLY the given fake
# package-manager binaries (each echoing "fake-<name> $*"), a fake `sudo`
# (existence-only — root acquisition just does `command -v sudo`; DRY mode
# never execs it), and the real sh/uname/id/sed the dry-run path actually
# calls — so PM detection always lands on the manager(s) under test and never
# races whatever apt-get/dnf/apk/brew (or sudo) the host itself ships. A plain
# "/usr/bin:/bin" fallback would re-expose apt-get (Linux CI ships it at
# /usr/bin/apt-get) or homebrew's own bin (macOS), defeating the shim. Echoes
# the dir path; caller removes it.
mk_pm_shim() {
    d="$(mktemp -d "${TMPDIR:-/tmp}/pf-pmshim-XXXXXX")"
    for pm in "$@"; do
        printf '#!/bin/sh\necho "fake-%s $*"\n' "$pm" > "${d}/${pm}"; chmod +x "${d}/${pm}"
    done
    printf '#!/bin/sh\nexit 0\n' > "${d}/sudo"; chmod +x "${d}/sudo"
    for real in sh uname id sed; do
        real_path="$(command -v "$real")" || die "test host is missing ${real}"
        ln -s "${real_path}" "${d}/${real}"
    done
    printf '%s\n' "${d}"
}

# mk_brew_shim — single-manager alias kept for the existing brew call sites below.
mk_brew_shim() { mk_pm_shim brew; }

# ---- (3e) brew as pure root refuses install (no SUDO_USER) ------------------
say "nginx consent: brew + root + no SUDO_USER -> tips, no brew install"
BREWSHIM="$(mk_brew_shim)"
out="$(PATH="${BREWSHIM}" BURROWEE_PREFLIGHT_DRY=1 BURROWEE_NGINX_INSTALL=1 SUDO_USER= sh edge/preflight.sh 2>&1)" \
    || die "brew root dry-run exited non-zero"
printf '%s\n' "${out}" | grep -q 'package manager: brew' || die "expected brew detection; got:\n${out}"
if [ "$(id -u)" = 0 ]; then
    printf '%s\n' "${out}" | grep -q '\[dry\].*brew install nginx' && die "pure-root brew must not install; got:\n${out}"
fi
rm -rf "${BREWSHIM}"

# ---- (3f) brew + root + SUDO_USER set -> sudo -u <user> brew install nginx --
# Off this uid (non-root, the common case on CI), nginx_install's brew branch
# never reaches the id-u-0 check, so it always renders the plain `brew install
# nginx` form regardless of SUDO_USER — assert whichever form this uid
# actually reaches (mirrors the (3e)/(3g) id -u conditional; never fake uid 0).
say "nginx consent: brew + SUDO_USER=someuser -> sudo -u install verb as root, plain as non-root"
BREWSHIM="$(mk_brew_shim)"
out="$(PATH="${BREWSHIM}" BURROWEE_PREFLIGHT_DRY=1 BURROWEE_NGINX_INSTALL=1 SUDO_USER=someuser sh edge/preflight.sh 2>&1)" \
    || die "brew SUDO_USER dry-run exited non-zero"
printf '%s\n' "${out}" | grep -q 'package manager: brew' || die "expected brew detection; got:\n${out}"
if [ "$(id -u)" = 0 ]; then
    printf '%s\n' "${out}" | grep -q '\[dry\].*sudo -u someuser brew install nginx' \
        || die "expected sudo -u drop-privilege install verb as root; got:\n${out}"
else
    printf '%s\n' "${out}" | grep -q '\[dry\].*brew install nginx' \
        || die "expected plain brew install verb as non-root; got:\n${out}"
    printf '%s\n' "${out}" | grep -q 'sudo -u someuser' \
        && die "non-root must not render the sudo -u drop-privilege form; got:\n${out}"
fi
rm -rf "${BREWSHIM}"

# ---- (3g) brew MODE=service -> brew services start (root direct, else sudo) -
# nginx present but not running: fake `nginx` (present) + a `pgrep` that
# exits 1 (nginx_running -> false) forces MODE=service.
say "nginx consent: brew MODE=service -> brew services start nginx (root direct vs sudo)"
BREWSHIM="$(mk_brew_shim)"
printf '#!/bin/sh\nexit 0\n' > "${BREWSHIM}/nginx"; chmod +x "${BREWSHIM}/nginx"
printf '#!/bin/sh\nexit 1\n' > "${BREWSHIM}/pgrep";  chmod +x "${BREWSHIM}/pgrep"
out="$(PATH="${BREWSHIM}" BURROWEE_PREFLIGHT_DRY=1 BURROWEE_NGINX_INSTALL=1 SUDO_USER= sh edge/preflight.sh 2>&1)" \
    || die "brew service-mode dry-run exited non-zero"
printf '%s\n' "${out}" | grep -q 'nginx is installed but not running as a service' \
    || die "expected MODE=service detection; got:\n${out}"
if [ "$(id -u)" = 0 ]; then
    printf '%s\n' "${out}" | grep -q '\[dry\] brew services start nginx' \
        || die "expected root brew services start verb (no sudo); got:\n${out}"
else
    printf '%s\n' "${out}" | grep -q '\[dry\] sudo brew services start nginx' \
        || die "expected non-root sudo brew services start verb; got:\n${out}"
fi
rm -rf "${BREWSHIM}"

# ---- (3h) dnf/apk: pin the per-PM install + service literals too ------------
# (3b)-(3g) only ever exercise apt/brew — dnf/apk template drift (a typo in
# nginx_install's or nginx_guide's dnf/apk case arms) would pass the whole
# suite silently. Pin both the consented dry-run verbs and the tips-block text.
say "nginx consent: dnf auto-yes dry-runs the dnf recipe"
DNFSHIM="$(mk_pm_shim dnf)"
out="$(PATH="${DNFSHIM}" BURROWEE_PREFLIGHT_DRY=1 BURROWEE_NGINX_INSTALL=1 sh edge/preflight.sh 2>&1)" \
    || die "dnf auto-yes dry-run exited non-zero"
printf '%s\n' "${out}" | grep -q 'package manager: dnf'                    || die "expected dnf detection; got:\n${out}"
printf '%s\n' "${out}" | grep -q '\[dry\].*dnf install -y nginx'           || die "expected dnf nginx install verb; got:\n${out}"
printf '%s\n' "${out}" | grep -q '\[dry\].*systemctl enable --now nginx'   || die "expected systemctl enable verb; got:\n${out}"
rm -rf "${DNFSHIM}"

say "nginx consent: dnf auto-no pins the dnf tips-block literals"
DNFSHIM="$(mk_pm_shim dnf)"
out="$(PATH="${DNFSHIM}" BURROWEE_PREFLIGHT_DRY=1 BURROWEE_NGINX_INSTALL=0 sh edge/preflight.sh 2>&1)" \
    || die "dnf auto-no dry-run exited non-zero"
printf '%s\n' "${out}" | grep -q 'dnf install -y nginx'                    || die "expected dnf tips install line; got:\n${out}"
printf '%s\n' "${out}" | grep -q 'systemctl enable --now nginx'            || die "expected dnf tips service line; got:\n${out}"
printf '%s\n' "${out}" | grep -q '\[dry\].*install -y nginx'               && die "auto-no must not run install verbs; got:\n${out}"
rm -rf "${DNFSHIM}"

say "nginx consent: apk auto-yes dry-runs the apk recipe"
APKSHIM="$(mk_pm_shim apk)"
out="$(PATH="${APKSHIM}" BURROWEE_PREFLIGHT_DRY=1 BURROWEE_NGINX_INSTALL=1 sh edge/preflight.sh 2>&1)" \
    || die "apk auto-yes dry-run exited non-zero"
printf '%s\n' "${out}" | grep -q 'package manager: apk'                    || die "expected apk detection; got:\n${out}"
printf '%s\n' "${out}" | grep -q '\[dry\].*apk add nginx nginx-mod-stream' || die "expected apk nginx install verb; got:\n${out}"
printf '%s\n' "${out}" | grep -q '\[dry\].*rc-update add nginx default'    || die "expected rc-update verb; got:\n${out}"
printf '%s\n' "${out}" | grep -q 'rc-service nginx start'                  || die "expected rc-service start verb; got:\n${out}"
rm -rf "${APKSHIM}"

# ---- (4) SKIP_NGINX drops the nginx group -----------------------------------
say "BURROWEE_SKIP_NGINX=1 drops the nginx group"
out_skip="$(PATH="${SHIM}:${PATH}" BURROWEE_PREFLIGHT_DRY=1 BURROWEE_SKIP_NGINX=1 sh edge/preflight.sh 2>&1)" \
    || die "skip-nginx dry-run exited non-zero"
printf '%s\n' "${out_skip}" | grep -q 'edge front: nginx' \
    && die "nginx group should be skipped under BURROWEE_SKIP_NGINX=1"

# ---- (5) install.sh pins the generated preflight ----------------------------
say "edge/install.sh @PREFLIGHT_SHA256@ matches sha256(edge/preflight.sh)"
baked="$(grep -E '^PREFLIGHT_SHA256=' edge/install.sh | sed -E 's/^PREFLIGHT_SHA256="([^"]*)".*/\1/')"
actual="$(sha256_of edge/preflight.sh)"
[ -n "${baked}" ] || die "no PREFLIGHT_SHA256 baked in edge/install.sh"
[ "${baked}" = "${actual}" ] || die "pin mismatch: baked=${baked} actual=${actual}"

printf '\nPREFLIGHT-TEST OK\n'

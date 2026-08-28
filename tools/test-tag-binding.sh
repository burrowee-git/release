#!/usr/bin/env bash
# test-tag-binding.sh — prove the outer bootstrap binds the verified bytes to
# the resolved release TAG, not merely to the signing key.
#
# Mirrors the offline BURROWEE_DL_BASE pattern of test-r2-fallback.sh. No
# GitHub, no nsm, no release tooling: the signed artifact set is fabricated
# here with an ephemeral minisign key.
#
# What this covers:
#   DRIFT:         the four committed <comp>/install.sh (and relay/install.sh)
#                  are byte-identical to a fresh gen-bootstraps.sh render — i.e.
#                  nobody hand-edited a generated bootstrap.
#   MATCH PATH:    trusted comment "burrowee <comp> <stamp>" == the resolved tag
#                  → verification passes and the inner installer runs.
#   ROLLBACK PATH: a triple that is FULLY VALID (same key, correct sha256, sums
#                  entry present) but whose trusted comment names an OLDER
#                  version → the installer aborts non-zero and installs nothing.
#                  This is the mirror-served silent-downgrade attack.
#   LEGACY PATH:   a signature with minisign's DEFAULT comment (no -t, i.e. the
#                  pre-fix rkit signer) → also rejected, fail-closed.
#
# Requires: minisign, python3 (http.server), zip.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# ---- tool paths (the Burrowee per-dir hook strips /opt/homebrew/bin) ---------
export PATH="/opt/homebrew/bin:${PATH}"
MINISIGN="${MINISIGN:-minisign}"
command -v "${MINISIGN}" >/dev/null 2>&1 || MINISIGN="/opt/homebrew/bin/minisign"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\n✗ TAG-BINDING TEST FAILED: %s\n' "$*" >&2; exit 1; }

# The beta.* entries only exist while a beta cycle is open (versions/<comp>.beta.stamp
# present — see tools/gen-bootstraps.sh) — absent today for every component in this
# repo. They are listed anyway: TestTestSuitesRestoreEveryRenderedArtifact
# (cmd/rkit/upgrade_bootstrap_test.go) requires every suite that re-renders the
# bootstraps to name every artifact gen-bootstraps.sh can produce, so a future cut
# that opens a beta cycle does not silently leave a TEST-keyed beta.*.sh behind. The
# save/restore/drift logic below is written to tolerate an entry that does not exist,
# in either direction.
GENERATED="cli/install.sh gateway/install.sh edge/install.sh agent/install.sh relay/install.sh
cli/upgrade.sh gateway/upgrade.sh edge/upgrade.sh agent/upgrade.sh
cli/preflight.sh gateway/preflight.sh edge/preflight.sh agent/preflight.sh
edge/updater.install.sh gateway/updater.install.sh
cli/beta.install.sh gateway/beta.install.sh edge/beta.install.sh agent/beta.install.sh
cli/beta.upgrade.sh gateway/beta.upgrade.sh edge/beta.upgrade.sh agent/beta.upgrade.sh
edge/beta.updater.install.sh gateway/beta.updater.install.sh"

# ---- work dir + cleanup ------------------------------------------------------
# The bootstraps are regenerated twice below (real key, then an ephemeral one),
# so stash their pre-test bytes and restore THOSE on exit — never `git checkout`,
# which would also throw away a contributor's uncommitted work.
W="$(mktemp -d "${TMPDIR:-/tmp}/test-tag-binding-XXXXXX")"
SERVER_PID=""
mkdir -p "${W}/orig"
for f in ${GENERATED}; do
    [ -f "${REPO_ROOT}/${f}" ] || continue   # not rendered (e.g. no beta cycle open) — nothing to save
    mkdir -p "${W}/orig/$(dirname "${f}")"
    cp "${REPO_ROOT}/${f}" "${W}/orig/${f}"
done

cleanup() {
    [ -n "${SERVER_PID}" ] && kill "${SERVER_PID}" 2>/dev/null || true
    for g in ${GENERATED}; do
        if [ -f "${W}/orig/${g}" ]; then
            cp "${W}/orig/${g}" "${REPO_ROOT}/${g}"
        else
            rm -f "${REPO_ROOT}/${g}"
        fi
    done
    rm -rf "${W}"
}
trap cleanup EXIT INT TERM

# ---- (0) DRIFT: generated bootstraps match their templates -------------------
# Run FIRST, before the ephemeral key rewrites them. gen-bootstraps.sh bakes the
# repo's real burrowee-release.pub, so a re-render must reproduce the checked-in
# files byte for byte — a hand-edited bootstrap shows up right here.
say "DRIFT: gen-bootstraps.sh reproduces the checked-in bootstraps"
sh tools/gen-bootstraps.sh >/dev/null
for f in ${GENERATED}; do
    had_before=0; [ -f "${W}/orig/${f}" ] && had_before=1
    has_after=0;  [ -f "${REPO_ROOT}/${f}" ] && has_after=1
    if [ "${had_before}" = 0 ] && [ "${has_after}" = 0 ]; then
        continue   # never rendered before or after (no beta cycle open) — nothing to compare
    fi
    if [ "${had_before}" != "${has_after}" ]; then
        die "${f} existence changed across regeneration (existed before: ${had_before}, exists after: ${has_after}) — drifted"
    fi
    diff -u "${W}/orig/${f}" "${REPO_ROOT}/${f}" >&2 \
        || die "${f} drifted from its template — edit tools/*.template.sh and re-run tools/gen-bootstraps.sh, never the generated file"
done
printf '  OK: all five bootstraps are in sync with their templates\n'

# ---- platform detection ------------------------------------------------------
case "$(uname -s)" in Darwin) OS=darwin ;; Linux) OS=linux ;; *) die "unsupported OS" ;; esac
case "$(uname -m)" in arm64|aarch64) ARCH=arm64 ;; x86_64|amd64) ARCH=amd64 ;; *) die "unsupported arch" ;; esac

COMP=cli
PORT="${TAG_BINDING_PORT:-8834}"
STAMP="v0.1.99.2026.07.26.deadbeef"          # the version we ask for
OLD_STAMP="v0.1.10.2026.01.01.0ldc0de"       # a genuinely signed OLDER release
TAG="${COMP}/${STAMP}"

# ---- (1) fabricate one signed artifact set ----------------------------------
say "building a signed artifact set (ephemeral key)"
mkdir -p "${W}/inner" "${W}/assets"
cat > "${W}/inner/install.sh" <<'INNER'
#!/bin/sh
printf '  -> inner installer: TAG_BINDING_INNER_OK\n'
exit 0
INNER

ZIP_NAME="burrowee-${COMP}-${OS}-${ARCH}.zip"
( cd "${W}/inner" && zip -q "${W}/assets/${ZIP_NAME}" install.sh )

if command -v shasum >/dev/null 2>&1; then
    ( cd "${W}/assets" && shasum -a 256 "${ZIP_NAME}" > SHA256SUMS.txt )
elif command -v sha256sum >/dev/null 2>&1; then
    ( cd "${W}/assets" && sha256sum "${ZIP_NAME}" > SHA256SUMS.txt )
else
    die "need shasum or sha256sum"
fi

"${MINISIGN}" -G -p "${W}/test.pub" -s "${W}/test.sec" -W >/dev/null 2>&1 \
    || die "minisign -G failed — is minisign installed?"

# Three signatures over the SAME sums file, differing only in trusted comment.
sign_as() {  # sign_as <out.minisig> [<-t value>...]
    local out="$1"; shift
    "${MINISIGN}" -S -s "${W}/test.sec" -m "${W}/assets/SHA256SUMS.txt" \
        -x "${out}" "$@" >/dev/null 2>&1 || die "minisign -S failed for ${out}"
}
sign_as "${W}/sig-match.minisig"    -t "burrowee ${COMP} ${STAMP}"
sign_as "${W}/sig-rollback.minisig" -t "burrowee ${COMP} ${OLD_STAMP}"
sign_as "${W}/sig-legacy.minisig"   # no -t: minisign's default comment

# ---- (2) render the bootstraps against the ephemeral pubkey ------------------
say "gen-bootstraps.sh (baking ephemeral test pubkey)"
BURROWEE_PUBKEY_FILE="${W}/test.pub" sh tools/gen-bootstraps.sh >/dev/null

# ---- (3) serve the assets ----------------------------------------------------
say "serving ${W}/assets/ on 127.0.0.1:${PORT}"
( cd "${W}/assets" && exec python3 -m http.server "${PORT}" --bind 127.0.0.1 ) >/dev/null 2>&1 &
SERVER_PID=$!
i=0
until curl -fsS "http://127.0.0.1:${PORT}/${ZIP_NAME}" -o /dev/null 2>/dev/null; do
    i=$((i+1)); [ "${i}" -lt 80 ] || die "http server did not come up on ${PORT}"
    sleep 0.1
done

SYSTEM_ONLY_PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

# run_install <sig-file> <prefix> — swaps in the signature under test and runs
# the real generated bootstrap, pinned to $TAG, against the local asset server.
run_install() {
    cp "$1" "${W}/assets/SHA256SUMS.txt.minisig"
    BURROWEE_DL_BASE="http://127.0.0.1:${PORT}" \
    BURROWEE_CLI_VERSION="${TAG}" \
    BURROWEE_SKIP_PREFLIGHT=1 \
    BURROWEE_NO_PATH_EDIT=1 \
    PREFIX="$2" \
    PATH="${SYSTEM_ONLY_PATH}" \
        sh "${REPO_ROOT}/${COMP}/install.sh" 2>&1
}

# ---- (4) MATCH PATH ----------------------------------------------------------
say "MATCH: trusted comment names the resolved tag → install proceeds"
out="$(run_install "${W}/sig-match.minisig" "${W}/prefix-match")" \
    || die "MATCH: installer exited non-zero:\n${out}"
case "${out}" in
    *"version binding verified"*) : ;;
    *) die "MATCH: missing the version-binding confirmation; got:\n${out}" ;;
esac
case "${out}" in
    *TAG_BINDING_INNER_OK*) printf '\nMATCH-PATH OK\n' ;;
    *) die "MATCH: inner installer did not run; got:\n${out}" ;;
esac

# ---- (5) ROLLBACK PATH -------------------------------------------------------
# Everything verifies EXCEPT the version: same key, same sums file, same zip.
# Pre-fix this installed the old release silently.
say "ROLLBACK: same key + valid sha256, trusted comment names an OLDER version → abort"
set +e
out="$(run_install "${W}/sig-rollback.minisig" "${W}/prefix-rollback")"
rc=$?
set -e
[ "${rc}" -ne 0 ] || die "ROLLBACK: installer returned 0 — a downgrade was accepted"
case "${out}" in
    *"version binding failed"*) : ;;
    *) die "ROLLBACK: aborted, but not on the version binding; got:\n${out}" ;;
esac
case "${out}" in
    *"${OLD_STAMP}"*) : ;;
    *) die "ROLLBACK: error should name the version actually signed; got:\n${out}" ;;
esac
[ ! -e "${W}/prefix-rollback" ] || die "ROLLBACK: installer wrote to PREFIX despite aborting"
case "${out}" in
    *TAG_BINDING_INNER_OK*) die "ROLLBACK: inner installer ran despite the abort" ;;
esac
printf '\nROLLBACK-PATH OK\n'

# ---- (6) LEGACY PATH ---------------------------------------------------------
say "LEGACY: signature with minisign's default comment (no -t) → abort"
set +e
out="$(run_install "${W}/sig-legacy.minisig" "${W}/prefix-legacy")"
rc=$?
set -e
[ "${rc}" -ne 0 ] || die "LEGACY: installer returned 0 — an unstamped release was accepted"
case "${out}" in
    *"version binding failed"*) printf '\nLEGACY-PATH OK\n' ;;
    *) die "LEGACY: aborted, but not on the version binding; got:\n${out}" ;;
esac
[ ! -e "${W}/prefix-legacy" ] || die "LEGACY: installer wrote to PREFIX despite aborting"

printf '\n  TAG-BINDING TEST PASSED (drift + match + rollback + legacy)\n'

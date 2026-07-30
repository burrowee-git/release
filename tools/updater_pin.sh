# updater_pin.sh — release-time updater version stamp helper, sourced by tools/build.sh.
# Kept self-contained so it can be sourced without executing a build (build.sh has
# no source-only guard — it is `set -euo pipefail` followed by a top-level body).

# updater_pin <mod-dir> — resolve the github.com/burrowee-git/core/updater pin from
# the given module dir (relay's updater build_dir is the nested `cli` module) and
# return the updater's full stamp: <semver>.<YYYY.MM.DD>.<sha8>.
#
# All three parts come from the PIN's own module metadata, never from this cut, so
# the stamp is FROZEN while the pin is unchanged — the property this function has
# always existed to protect (the updater must not be re-versioned by a cut that
# did not repin core/updater) now extended to the date and fingerprint. Same freeze
# semantics as versions/burrowee.stamp for the dispatcher.
#
# The metadata comes from `go mod download -json`, whose .info file carries
# Version, Time and Origin.Hash. `go list -m` does NOT surface Origin, which is
# why the .info file is read rather than queried; reading the path go itself
# reports avoids hand-constructing $GOMODCACHE/cache/download/... paths.
#
# FAIL CLOSED on every unresolvable field. A missing Time or Origin.Hash would
# otherwise yield "v0.1.12.." or "v0.1.12.2026.07.26." — a malformed stamp that
# reaches the console catalog and the fleet. The extractions below are deliberately
# strict for the same reason: if go's output format ever changes, the empty result
# aborts the cut instead of shipping a wrong version.
updater_pin() {
    local mod_dir="$1"
    local v info raw time_raw hash date fp
    v="$(cd "${mod_dir}" && "${GO_BIN:-go}" list -m -f '{{.Version}}' github.com/burrowee-git/core/updater)"
    case "${v}" in
        v[0-9]*.[0-9]*.[0-9]*) : ;;   # clean tag
        *) echo "✗ core/updater pinned to non-tag '${v}' in ${mod_dir} — repin to a tag before cut" >&2; exit 1 ;;
    esac
    case "${v}" in
        *-*) echo "✗ core/updater pin '${v}' is a pseudo-version — repin to a tag before cut" >&2; exit 1 ;;
    esac

    info="$(cd "${mod_dir}" && "${GO_BIN:-go}" mod download -json github.com/burrowee-git/core/updater \
            | sed -n 's/.*"Info"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    [ -n "${info}" ] && [ -f "${info}" ] || {
        echo "✗ core/updater ${v}: could not resolve module .info path via 'go mod download -json' in ${mod_dir}" >&2; exit 1; }
    raw="$(cat "${info}")"

    time_raw="$(printf '%s' "${raw}" | sed -n 's/.*"Time"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    date="$(printf '%s' "${time_raw}" | sed -n 's/^\([0-9][0-9][0-9][0-9]\)-\([0-9][0-9]\)-\([0-9][0-9]\).*/\1.\2.\3/p')"
    [ -n "${date}" ] || {
        echo "✗ core/updater ${v}: no usable Time in ${info} (got '${time_raw}') — refusing to ship a malformed updater stamp" >&2; exit 1; }

    hash="$(printf '%s' "${raw}" | sed -n 's/.*"Hash"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p')"
    case "${hash}" in
        ????????*) fp="${hash:0:8}" ;;
        *) echo "✗ core/updater ${v}: no usable Origin.Hash in ${info} (got '${hash}') — refusing to ship a malformed updater stamp" >&2; exit 1 ;;
    esac

    printf '%s.%s.%s' "${v}" "${date}" "${fp}"
}

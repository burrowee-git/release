# updater_pin.sh — release-time updater version stamp helper, sourced by tools/build.sh.
# Kept self-contained so it can be sourced without executing a build (build.sh has
# no source-only guard — it is `set -euo pipefail` followed by a top-level body).

# updater_pin <mod-dir> — resolve the github.com/burrowee-git/core/updater pin from
# the given module dir (relay's updater build_dir is the nested `cli` module) and
# return the updater's full stamp: <semver>.<YYYY.MM.DD>.<sha8>. A pre-release
# tag's hyphen is rendered as a dot (v0.3.0-beta.1 → v0.3.0.beta.1.<date>.<sha8>),
# because every shipped stamp uses the dotted infix (versions/*.beta.stamp's
# v0.2.17.beta.…) and the ladder's parser reads dot-separated fields — a hyphen
# would be a shape nothing downstream has ever parsed.
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
    # A TAG, and the same set internal/relconfig's cleanTag accepts — the two
    # validators are asserted to mirror each other, and a glob that took
    # `v0.3.0+build.7` or `v0.3.0-dirty` while the Go side refused them would
    # render a stamp shape nothing downstream parses on one produce path and
    # abort the cut on the other. Numeric MAJOR.MINOR.PATCH, optionally one
    # dot-separated alphanumeric pre-release; no build metadata, no hyphen
    # inside the pre-release.
    if ! printf '%s' "${v}" | grep -Eq -- '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.]*)?$'; then
        echo "✗ core/updater pinned to non-tag '${v}' in ${mod_dir} — repin to a tag before cut" >&2; exit 1
    fi
    # A PSEUDO-VERSION is refused; a semver PRE-RELEASE tag is not. The two
    # share the hyphen — core/updater sits on core/vX.Y.0-beta.N for the whole
    # of a beta cycle, and the blanket `*-*` refusal made every beta cut die
    # here — but only the pseudo-version means "this pin is not a tag at all".
    # What identifies one is its machine-minted tail: a 14-digit UTC timestamp
    # and a 12-hex-digit commit prefix, with or without the canonical `.0.`
    # rung before it (vX.Y.Z-0.<ts>-<hash>, vX.Y.Z-pre.0.<ts>-<hash>). A tail
    # of that shape that go would not mint is still refused — fail closed: no
    # human tags a timestamp-and-hash, and a cut must not freeze the updater
    # to an untagged commit.
    if printf '%s' "${v}" | grep -Eq -- '[.-]([0-9A-Za-z.-]*\.)?[0-9]{14}-[0-9a-f]{12}$'; then
        echo "✗ core/updater pin '${v}' is a pseudo-version — repin to a tag before cut" >&2; exit 1
    fi

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

    # The dotted infix: a pre-release tag's hyphen becomes a dot in the stamp
    # (see the header). A clean tag passes through tr unchanged.
    printf '%s.%s.%s' "$(printf '%s' "${v}" | tr - .)" "${date}" "${fp}"
}

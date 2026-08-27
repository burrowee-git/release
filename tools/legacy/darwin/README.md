# `tools/legacy/darwin` — the darwin-amd64-legacy `crypto/x509` overlay

## What this is

Go ≥ 1.25 verifies TLS chains on darwin via `SecTrustCopyCertificateChain`, a
macOS 12 API that `crypto/x509` imports non-lazily — so any darwin binary
built with a current Go toolchain dies at launch (before `main`) on macOS
10.15/11 with `dyld: Symbol not found: _SecTrustCopyCertificateChain`.

This directory holds a `go build -overlay` replacement for the three
`crypto/x509` files that reference that symbol, swapping the Go 1.24
chain-walk (`SecTrustGetCertificateCount` + `SecTrustGetCertificateAtIndex`,
present since macOS 10.7, deprecated-but-present through current macOS) back
in. It changes nothing else about the build: same toolchain, same module
pins, same CVE gate, same signing/notarization — only these three files are
swapped for the `darwin-amd64-legacy` release target.

Full design: `docs/specs/2026-08-27-darwin-legacy-build-design.md` §3–§4.1 in
`burrowee-git/resources`.

## Files

| File | Role |
|---|---|
| `root_darwin.go` | `crypto/x509/root_darwin.go` with the chain-loop hunk swapped for the index walk |
| `security.go` | `crypto/x509/internal/macos/security.go` with `SecTrustCopyCertificateChain` removed and `SecTrustGetCertificateCount` + `SecTrustGetCertificateAtIndex` added |
| `security.s` | the matching two trampolines added, one removed |
| `GO_VERSION` | the exact `go version` these three files were derived from — the pin the drift guard checks against |
| `overlay.test.sh` | the drift guard (see below) |
| `overlay-json.sh <out-file>` | writes the `go build -overlay` JSON (absolute GOROOT paths) mapping the three stdlib files to the ones in this directory |

## The drift guard

`overlay.test.sh` is what stops this overlay from silently falling behind or
silently failing to apply after a Go bump. It passes only when:

1. `go version` matches `GO_VERSION` exactly, and
2. each of the three files here differs from the *live* `$(go env
   GOROOT)/src/...` original only inside the hunks this overlay is allowed to
   own (the chain loop; the import/wrapper block; the trampolines) — any other
   difference (i.e. upstream Go touched something else in these files between
   the pinned minor and the one actually installed) fails the check, and
3. the overlay files still actually drop the macOS-12-only symbol and still
   walk the chain by index (belt-and-braces content checks, independent of
   the diff-based check above).

A future Go bump — even a patch release — therefore fails this test until a
human re-derives the overlay, rather than silently shipping a stale overlay
that either doesn't apply or reintroduces the macOS-12 symbol.

Nothing under `tools/legacy/darwin/` runs this test automatically at build
time from here — that wiring (`build.sh` invoking `overlay.test.sh` before
building the `legacy` variant, per spec §4.2) is a later task.

## Go-bump procedure

When `overlay.test.sh` starts failing because the installed Go minor no
longer matches `GO_VERSION` (or because upstream touched one of the three
files outside the expected hunks):

1. Copy the three fresh originals from the new `$(go env GOROOT)/src/...`:
   - `crypto/x509/root_darwin.go` → `root_darwin.go`
   - `crypto/x509/internal/macos/security.go` → `security.go`
   - `crypto/x509/internal/macos/security.s` → `security.s`
2. Re-apply the same three edits (see spec §4.1 for the exact hunks, or diff
   the previous committed versions of these files against their previous
   GOROOT originals to see exactly what changed):
   - `root_darwin.go`: replace the `SecTrustCopyCertificateChain` +
     `CFArrayGetCount`/`CFArrayGetValueAtIndex` loop with the
     `SecTrustGetCertificateCount` + `SecTrustGetCertificateAtIndex` index
     walk.
   - `security.go`: remove the `SecTrustCopyCertificateChain` cgo import +
     wrapper + trampoline declaration; add the `SecTrustGetCertificateCount`
     and `SecTrustGetCertificateAtIndex` cgo imports + wrappers + trampoline
     declarations.
   - `security.s`: remove the `x509_SecTrustCopyCertificateChain_trampoline`
     `TEXT` block; add the two matching `TEXT` blocks for
     `x509_SecTrustGetCertificateCount_trampoline` and
     `x509_SecTrustGetCertificateAtIndex_trampoline`.
3. Update `GO_VERSION` to the new `go version | awk '{print $3}'` output.
4. Run `bash tools/legacy/darwin/overlay.test.sh` — every line must read
   `ok:`.
5. Re-run the build-time symbol assertions (nm on a built `legacy` binary
   must not import `_SecTrustCopyCertificateChain` and must import
   `_SecTrustGetCertificateAtIndex`) before shipping.
6. Commit the four changed files together — the overlay and its pin never
   drift apart.

If Apple ever removes `SecTrustGetCertificateAtIndex` (deprecated since macOS
12, still present through current releases as of this writing), or the
overlay can no longer be made to apply, the variant is dropped per spec §9 —
this is not a case to work around.

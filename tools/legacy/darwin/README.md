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
| `_src/root_darwin.go` | `crypto/x509/root_darwin.go` with the chain-loop hunk swapped for the index walk |
| `_src/security.go` | `crypto/x509/internal/macos/security.go` with `SecTrustCopyCertificateChain` removed and `SecTrustGetCertificateCount` + `SecTrustGetCertificateAtIndex` added |
| `_src/security.s` | the matching two trampolines added, one removed |
| `GO_VERSION` | the exact `go version` these three files were derived from — the pin the drift guard checks against |
| `overlay.test.sh` | the drift guard (see below) |
| `overlay-json.sh <out-file>` | writes the `go build -overlay` JSON (absolute GOROOT paths) mapping the three stdlib files to the ones in `_src/` |

### Why the three sources live in `_src/`, not here directly

`root_darwin.go` declares `package x509`; `security.go` and `security.s`
belong to `package macos`. That's correct — they're verbatim (edited) copies
of two different stdlib packages — but it means two conflicting package
clauses sitting directly in `tools/legacy/darwin/` make the Go tool treat
the directory itself as an ill-formed Go package: `go build ./...`,
`go vet ./...` and `go test ./...` all refuse with `found packages x509
(root_darwin.go) and macos (security.go) in .../tools/legacy/darwin`, which
breaks the whole module, not just this directory.

These files are never meant to be compiled as part of this module in the
first place — they're consumed exclusively by `go build -overlay` as raw
file substitutions, so the Go tool has no business discovering them as a
package at all. Moving them into `_src/` (a directory name that starts with
`_`) fixes that: **the Go tool skips any directory whose name begins with
`_` or `.` during package discovery** (same treatment as `testdata/`, just a
different name), so `go build ./...` / `go vet ./...` / `go test ./...`
never look inside `_src/` and the conflicting package clauses become
invisible to them, while `overlay.test.sh` and `overlay-json.sh` — which
read these files by explicit path, not by Go package discovery — work
exactly as before. `GO_VERSION`, `overlay.test.sh`, `overlay-json.sh` and
this README stay directly in `tools/legacy/darwin/` since none of them are
Go source and none of them trip package discovery.

**Do not move `root_darwin.go` / `security.go` / `security.s` back out of
`_src/` "to tidy the layout."** Putting them beside `overlay.test.sh` again
reintroduces the module-wide build/vet/test breakage this section exists to
prevent — `tools/build.sh` (Task A4) locates them only through
`overlay-json.sh`, which already points at `_src/`, so nothing outside this
directory needs to change if `_src/` is ever renamed; only `overlay.test.sh`
and `overlay-json.sh` would need updating together with it.

## The drift guard

`overlay.test.sh` is what stops this overlay from silently falling behind or
silently failing to apply after a Go bump. It passes only when:

1. `go version` matches `GO_VERSION` exactly, and
2. every diff **hunk** (`diff`'s normal-format change block, not individual
   line) between each file here and its *live* `$(go env GOROOT)/src/...`
   original contains at least one line naming a symbol the overlay owns
   (`SecTrustCopyCertificateChain`, `SecTrustGetCertificateCount`,
   `SecTrustGetCertificateAtIndex`, `chainRef`, `CFArrayGetCount`,
   `CFArrayGetValueAtIndex`) — a hunk with none of those anchors anywhere in
   it fails the check, and
3. the overlay files still actually drop the macOS-12-only symbol and still
   walk the chain by index (belt-and-braces content checks, independent of
   the hunk-based check above).

A future Go bump — even a patch release — therefore fails this test until a
human re-derives the overlay, rather than silently shipping a stale overlay
that either doesn't apply or reintroduces the macOS-12 symbol.

### What the drift guard actually guarantees (and what it doesn't)

Check 2 is **hunk**-scoped, not line-scoped, on purpose: a hunk this overlay
legitimately owns (e.g. the chain-loop rewrite in `root_darwin.go`) mixes in
ordinary Go boilerplate — an `if err != nil {` follow-on, a bare closing
brace, `return int(ret)` — alongside the anchor symbols. An early version of
this guard tried to allowlist that boilerplate line-by-line, which meant any
line anywhere in the file matching one of those generic tokens was silently
accepted — including inside a completely unrelated hunk that never mentions
any owned symbol. Scoping the check to whole hunks closes that: the actual
guarantee is **"every changed hunk contains at least one line naming an
owned symbol somewhere in that hunk"**, which is stronger than line-by-line
but still not literally "only the expected three hunks changed and nothing
else." Two residual gaps to know about:

- A hunk that legitimately touches an owned symbol could, in principle,
  smuggle in an unrelated change *within that same hunk* (i.e. adjacent to
  an anchor line) — the guard does not diff hunk shape/line-count against a
  recorded expectation, only "does this hunk mention an owned symbol."
- The anchor list is substring matching, so a symbol name appearing inside a
  comment or string literal (not just real code) also satisfies it — this is
  why check 3 (the `SecTrustCopyCertificateChain` occurrence count) exists as
  an independent, non-hunk-based backstop rather than folding into check 2.

Both gaps are deliberate trade-offs of a `diff`+`awk` guard over hand-written
Go files, not oversights; a stronger guard would need something closer to an
AST diff. If that trade-off ever proves insufficient, tighten check 2 rather
than reverting to line-by-line matching.

`tools/build.sh` (`VARIANT=legacy`) runs `overlay.test.sh` before every legacy
build and refuses to build if it fails, per spec §4.2.

## Go-bump procedure

When `overlay.test.sh` starts failing because the installed Go minor no
longer matches `GO_VERSION` (or because upstream touched one of the three
files outside the expected hunks):

1. Copy the three fresh originals from the new `$(go env GOROOT)/src/...`
   into `_src/` (see "Why the three sources live in `_src/`" above — do not
   put them anywhere else):
   - `crypto/x509/root_darwin.go` → `_src/root_darwin.go`
   - `crypto/x509/internal/macos/security.go` → `_src/security.go`
   - `crypto/x509/internal/macos/security.s` → `_src/security.s`
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

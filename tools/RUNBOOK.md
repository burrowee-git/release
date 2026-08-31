# Operator runbook notes

Operator-only. Not needed to contribute code — see `CLAUDE.md` → "Scope of this
manual". Each note records a hazard that the tooling does **not** prevent.

---

## darwin-amd64-legacy: two landing-order hazards — read before cutting it

### (a) `rkit build` cannot produce this platform. This is unimplemented, not pending.

**`rkit build` is the primary produce path** (see the very next section below:
`tools/release.sh` never builds anything, it distributes what rkit already
staged into `dist/<stamp>/`). Today `rkit build` produces exactly the four
original targets — `darwin/arm64`, `darwin/amd64`, `linux/arm64`,
`linux/amd64` — and has no concept of a fifth target or of a build-time
overlay at all. The list is hardcoded in
`internal/relconfig/relconfig.go`'s `Targets()`, in the `burrowee-git/release`
module itself, and `cmd/rkit` has no `VARIANT=legacy` equivalent to
`tools/build.sh`'s.

Until `Targets()` (and `cmd/rkit`'s build loop) are taught the fifth target
and the `tools/legacy/darwin/` overlay — work that lives in a **fourth
repository, `burrowee-git/release-kit`**, which nothing in this effort's
spec, plan, or task briefs ever scoped — **`darwin-amd64-legacy` can only be
produced by `tools/release.sh`'s own full-cut path** (`do_release`, which
builds all five `TARGETS` itself under `set -e`), never by `rkit build` and
never by `release.sh --distribute-only` over an `rkit build` stage. An
operator running the documented `rkit build` → `--distribute-only` flow will
get four platforms, not five, and (as of this fix wave) `release.sh` now
refuses to register that short stage silently — see
`assert_platform_coverage` in `tools/release.sh` — but the fix is "fail
loudly", not "produce the fifth platform." Producing it from `rkit` is a
deliberate future decision for the operator to make in `release-kit`, not
something this repo can do on its own.

If you are knowingly distributing a partial stage anyway (e.g. re-running
`--distribute-only` for one already-known-short component), declare it
explicitly rather than working around the gate: `RELEASE_SH_EXPECT_MISSING`
(optionally component-scoped as `RELEASE_SH_EXPECT_MISSING_<COMP>`, e.g.
`RELEASE_SH_EXPECT_MISSING_CLI`) names the exact platform(s) expected
absent — space- or comma-separated — and is checked against the actual
missing set, not a count: a platform missing that you didn't declare still
fails, and a platform you declared that turns out NOT to be missing also
fails (so the declaration cannot outlive the gap it was written for). Never
set it for a real cut.

### (b) Landing order: the update path must not learn about this platform before core + console do

`darwin-amd64-legacy` exists specifically so a pre-macOS-12 Intel Mac gets a
build that doesn't die at `_SecTrustCopyCertificateChain` before `main`. That
protection covers **install** the moment this repo's bootstrap picks the
right platform by host. It does **not** yet cover **self-update**: today the
updater (`updater/fetch.go` et al.) and the gateway
(`internal/gateway/service_install.go`'s `OsArch()`) still compute the
platform as the bare `runtime.GOOS + "-" + runtime.GOARCH` — they have not
been taught the legacy platform key. Tasks B2 (updater) and B3 (gateway) —
re-pinning `updater/go.mod` to a tagged core that exposes the platform key,
and switching `OsArch()` to use it — have **not landed**.

The failure mode this creates is not a clean error, which is what makes it
dangerous: `darwin-amd64` **exists** in the release catalog (it's one of the
original four targets), so a Catalina host that installed the legacy build
via the bootstrap will, on its next self-update, ask the catalog for
`darwin-amd64` — a real, signed, notarized, perfectly valid entry — download
it, and install a binary that dies before `main` on that exact host. That is
the precise bug this entire effort exists to fix, reintroduced through the
one code path (self-update) that this work has not yet touched.

**Spec §13's landing order — core tagged and console-registered, then
`updater/go.mod` re-pinned (B2) and the gateway switched (B3), all landed
*before* the first `darwin-amd64-legacy` release is cut — is therefore a hard
gate, not a suggestion.** Cutting `darwin-amd64-legacy` ahead of that order
does not fail to help pre-macOS-12 hosts; it actively breaks them on their
first subsequent self-update, which is strictly worse than never having
built the platform at all — those hosts were, until this effort landed, at
least still running.

---

## Cutting a public release: the Apple environment

**`rkit build` is the primary produce path.** `tools/release.sh` never invokes
it — rkit builds, signs, checksums and stages into `dist/<stamp>/`; release.sh
distributes what rkit already staged (`"run rkit build first"` is what it says
when the stage is missing). They are two independent programs that share a
*precedence contract*, not an inherited environment.

So **`rkit build --apple` / `--public` needs the Apple environment set in its own
process.** It requires, and aborts without:

Both values resolve the same way — an exported variable first, then a config
file in this repo. The files are **gitignored**: that is what lets a public repo
resolve a machine path without carrying one, so nothing here is baked into the
source and nothing is derived from `$HOME` (unset under launchd, cron, and a
detached harness session, where a `$HOME`-derived default silently goes
*relative*).

| Value | Exported | Config file | Meaning |
|---|---|---|---|
| account | `$APPLE_ACCOUNT` | `config/apple-account` | one line: the account plugin folder name |
| home | `$APPLE_HOME` | `config/apple-home` | one line: the **absolute** directory holding one folder per Apple account |
| both | `$APPLE_ACCOUNT_DIR` | — | that account's folder directly; set it and neither file is consulted |

Create the two files once per machine and every later cut needs no environment
at all:

```sh
printf '<Account>\n'        > config/apple-account
printf '%s\n' "$HOME/<your-apple-plugin-root>" > config/apple-home
rkit build --component gateway --public --sign-key …
```

`tools/release.sh` resolves identically (`tools/apple_sign.sh`), so both entry
points now agree — the shell copy used to fall back to a baked `$HOME` path
while the Go copy refused to default at all.

**This is a fail-closed change, and deliberate.** `loadAppleAccount` used to
return silently on every failure mode — no config file, a comment-only config,
`APPLE_HOME` unset, a missing plugin folder — and `runBuild` ignored that it had
done nothing. `rkit build --public` then entered the Developer-ID path with no
account, and produced an **ad-hoc signed** build that the operator believed was
Developer-ID signed and notarized. It now aborts before compiling anything, with
a message naming exactly what to set. A `$HOME`-derived default was also removed
because it silently became a *relative* path whenever `HOME` was unset — launchd,
cron, a detached harness session — pointing the signer at
`./Workstation/Apple/<Account>` relative to the cwd.

`tools/release.sh` has **no** default of its own either, and that is the point of
the paragraph above: `load_apple_account()` (`tools/apple_sign.sh`) resolves
`$APPLE_HOME` first, then `config/apple-home`, and when neither answers it aborts
with `APPLE_HOME is unresolved` — the same refusal, for the same reason, that
`rkit build` gives. It hard-fails the same way on a missing plugin folder. Both
entry points resolve; neither defaults.

---

## The updater's version is the core/updater pin, not the cut

`burrowee-<comp>-updater` is stamped `<semver>.<YYYY.MM.DD>.<sha8>`, but unlike
every other binary that stamp is **not** derived from the component being cut.
It's resolved from the **`core/updater` pin's own module metadata**
(`go mod download -json` → the `.info` file's `Version`, `Time`,
`Origin.Hash`) — the same freeze semantics `versions/burrowee.stamp` gives the
dispatcher stamp. **Three** produce paths do this resolution, all sharing the
ONE bash helper `tools/updater_pin.sh`: `tools/build.sh` sources it directly to
stamp the `-updater` binary's `-X main.version`; `rkit` goes through the Go
mirror `internal/relconfig.UpdaterPin` (used by `rkit`, the primary produce
path per the Apple-environment note above), kept in lockstep with the bash
helper by a mirror test; and `tools/release.sh`'s `register_staged` — the
**only** writer of the console catalog's `updater_version`, which is the value
operators actually see — calls `tools/updater_pin.sh`'s `updater_pin()`
directly. All three fail closed on a missing or malformed `Time`/`Origin.Hash`
rather than shipping a malformed stamp — see `tools/test-updater-pin.sh`.

Consequences worth knowing before triaging an updater stamp:

- **Cutting a component twice without repinning `core/updater` ships the
  identical updater stamp both times.** That is correct: the binary is
  unchanged, and a re-dated stamp would make the console offer an updater
  update that changes nothing.
- **The date in an updater stamp is the date the `core/updater` tag was
  published**, so it will normally look *older* than the component's own
  stamp date. Not a staleness bug — don't "fix" it by re-dating.
- **The first cut of each component after this change re-stamps its
  updater** (`v0.1.12` → `v0.1.12.<date>.<sha8>`), so every node's updater
  self-update fires once: the up-to-date guard is exact string equality on
  the updater's own version, the strings differ, the swap happens, and the
  node converges. Expect **one updater swap per node, once per component** —
  then quiet. Not a rollout bug, and not worth re-cutting to "avoid".
- **`agent` ships no updater.** The shared-updater set is `cli`, `gateway`,
  `edge`, `relay` only — don't expect an agent stamp to carry one.

---

## Two releases can carry the same source SHA

**Observed:** `gateway/v0.1.94.2026.07.24.343fe73a` and
`gateway/v0.1.95.2026.07.24.343fe73a`. Both tags exist, each resolves to its own
commit, neither was re-pointed — the never-re-point rule was respected. But both
stamps end in the same source SHA, `343fe73a`.

**Why it happens.** A stamp is `v<semver>.<dateUTC>.<sourceSHA>` (see
`internal/relconfig/stamp.go`). Only the semver comes from `versions/<comp>`; the
SHA comes from the component source worktree's `git HEAD`. Cutting twice from an
unchanged source worktree — a bump plus a re-cut after a distribution failure, a
second cut to pick up a dependency repin that lives in another repo, a retry
after a notarization hiccup — advances the semver while the SHA stays put. The
tooling neither prevents this nor warns about it, and it is not in itself wrong:
the two releases really are two publications.

**What it costs.** "Which build is this node running" stops being answerable from
the SHA alone. A node reporting `343fe73a` may be on v0.1.94 or v0.1.95, and
those are different published payloads (different zips, different SHA256SUMS,
different GitHub release assets). Any triage step that reads the SHA — matching a
node's heartbeat against a source commit, bisecting a regression to a source
change, "is this node on the build that carries the fix" — is ambiguous across
such a pair. The SHA is also the part an operator eyeballs, so the ambiguity is
easy to miss.

**What to do.**

1. **Prefer not to create the pair.** Before a second cut from the same source,
   ask what changed. If the answer is "nothing in this component's source", the
   new release is distribution-only — use
   `tools/release.sh --distribute-only <comp> <stamp>` against the existing stamp
   instead of bumping the version. That republishes the same build under the same
   identity, which is what actually happened.
2. **If a real second cut is needed** (the payload genuinely differs — a repinned
   dependency in another repo, a rebuilt dispatcher), it is legitimate. Say so in
   the release notes: name what differs from the previous stamp, since the SHA
   cannot show it.
3. **When triaging, compare the full stamp, never the SHA suffix.** The semver is
   the only part that distinguishes the pair. Treat a bare SHA from a node report
   as ambiguous until the semver is confirmed.
4. **Do not "fix" history.** Both tags are published and installers have resolved
   them. Deleting or re-pointing either would break the never-re-point rule and
   invalidate the signed `SHA256SUMS.txt` a client may still be verifying
   against.

**Not a code change.** Making the stamp unique (a counter, a build timestamp)
would change the release identity format that installers, the console catalog and
every already-published tag depend on. The ambiguity is narrow, the cost of
changing the scheme is not.

---

## `--keep-version`: two releases can carry the same SEMVER

The mirror image of the section above, and it is opt-in rather than accidental.
`tools/release.sh <comp> --keep-version` leaves `versions/<comp>` exactly as it
is — no bump of any kind, not even the default patch — and mints a fresh stamp
over the component's current commit. It exists for one case: **a published
release whose payload was wrong, where the version number must not move.**

**What it costs.** Two published releases share a semver, distinguishable only
by the stamp's date and source-SHA segments. Anything that keys on the semver
alone — an operator reading `0.2.0` off a node, a pin written as a bare version,
a changelog entry — no longer identifies one payload. That is accepted
deliberately when the flag is used; it is not a bug to be reported later.

**What the tooling does and does not prevent.**

- It **refuses** when the resulting stamp already has a tag —
  `assert_stamp_untagged()` in `release.sh`, checked in step (1) before anything
  is built. Same semver **and** same UTC date **and** same source SHA is not a
  re-cut, it is the release that is already live.
- It **refuses** to combine with `--bump-minor`, `--bump-major`, `--force` or
  `--distribute-only` (exit 2), because each of those either moves the version
  this flag pins or never touches it at all.
- It does **not** stop you republishing a live semver. That is the feature.
  Every run says so in two places: a `→ … REPUBLISHING semver …` line from
  `resolve_comp_stamp()` and the cut header's `Bump    : none — --keep-version
  REPUBLISHES …`.

**The trap you will actually hit.** The stamp's date is **UTC today**. Re-cutting
the same component, from the same commit, on the same UTC day as the original cut
produces the *identical* stamp and is refused — correctly, since there is nothing
to distinguish the two tags. If the component source genuinely has not moved and
the payload fault was in **this** repo (a packaging bug, a missing directory in
the payload), `--keep-version` cannot help on that day: either wait for the UTC
date to roll, land a commit in the component repo, or accept the patch bump.

**Check before you run it.** `git tag -l "<comp>/v*" --sort=version:refname | tail`
against `versions/<comp>` and the component worktree's `git HEAD`. The refusal
only sees **local** tags — `git fetch --tags` first if this checkout may be behind
origin.

---

## `versions/burrowee.stamp` — the dispatcher-stamp freeze record

Records the last dispatcher stamp actually used, so `resolve_disp_stamp()`
(in `release.sh`) reuses it verbatim — date frozen — across cuts where the
`burrowee` dispatcher source hasn't changed, instead of re-dating it every
cut. A cut that aborts before its `[RELEASED]` marker commit has its staged
write to this file auto-reverted (`revert_dispatcher_version()`, the same
EXIT/INT/TERM trap that reverts `versions/burrowee`) — don't hand-edit it to
"fix" a dirty tree after a failed cut; re-running the cut is enough.

---

## `--distribute-only`'s staged-bump tolerance — narrow on purpose, and still not a push

`rkit build` (the primary produce path) stages `versions/<comp>` and
`versions/<comp>.stamp` — never commits them — so that `release.sh
--distribute-only`'s own `[RELEASED: <comp>]` marker commit is the one that
actually records the bump (cmd/rkit `buildRun` is where that staging, and
its on-failure revert, both happen). `git commit` with no pathspec commits the
whole index, so the marker commit picks up both staged files for free. **The
two-step path — `rkit build` then `--distribute-only` — costs exactly one
commit**, not two: don't read a two-commit cut as this path working correctly,
that shape is what the deadlock below used to force before the guard was
narrowed.

`assert_release_origin`'s clean-tree check (`tools/release_origin.sh`) tolerates
exactly those two staged paths, and nothing else, and only for the release
repo, and only inside the `--distribute-only` dispatch. Every other tree a cut
reads, and every other entry point, still gets zero tolerance. It still
refuses, exactly as before this exemption existed:

- a genuinely dirty tree (an edit outside the two tolerated paths, staged or not);
- an untracked file anywhere in the tree;
- `versions/<comp>` staged **and further modified** in the worktree (`MM`) —
  the stamp would have been computed from the worktree file while the marker
  commit records the index, so the two could disagree;
- a release repo that isn't exactly in sync with `origin/main` (behind, ahead,
  or diverged) — the staged-bump tolerance only widens the clean-tree check,
  it does not touch `origin_sync_status` at all.

**Residual 1 — the dispatcher bump is still a manual step.** `versions/burrowee`
is deliberately not in the tolerated set. If a dispatcher bump is needed for
this cut, commit and push it *before* running `rkit build` — there is no
tool-created deadlock to break there, only a commit to make in the ordinary
order. Staging a dispatcher bump alongside a component bump and expecting it
to ride the same marker commit is refused, on purpose (`versions/burrowee`
staged next to `versions/<comp>` fails the guard with "staged is tolerated for
exactly: …").

**Residual 2 — `release.sh` still never pushes.** The `[RELEASED]` marker
commit is made locally; there is no `git push` anywhere in `release.sh`. A
cut — full or `--distribute-only` — leaves the release repo one commit ahead
of `origin/main`, and the next cut or distribute is refused by the very
`origin_sync_status` check above until an operator pushes it. This is
unchanged by the staged-bump fix: fixing the deadlock did not remove the push
requirement, and reading it as removed is the trap. See
`docs/specs/2026-08-03-cut-origin-and-worktree-flow-design.md`
(`burrowee-git/resources`) for why the flow batches the push instead of doing
it here. Who does it: `tools/release.command` pushes each marker between
components (last section), because a batch cannot otherwise get past its own
second component; cut by hand and the push is yours to make.

**Residual 3 — a re-cut at an identical stamp leaves NOTHING to push.** When a
component is re-cut at the same semver and the same stamp (its tag deleted so
the stamp can be republished), `versions/<comp>`, `versions/<comp>.stamp` and
the regenerated bootstraps come out byte-identical to `HEAD`, so the index is
empty and there is no marker commit to make. `marker_commit()`
(`tools/marker_commit.sh`) detects exactly that, prints `→ marker: nothing to
record …`, and lets the cut finish 0 — it does **not** make an empty commit,
so unlike every other cut this one leaves the repo *in sync* with
`origin/main` and Residual 2's "push before the next cut" step has nothing to
push. That is correct, not a missed step: the marker for that stamp is already
in history, put there by the cut that first published it. Every *other*
non-zero from `git commit` — a rejecting hook, a held `index.lock`, a bad
committer identity — still aborts the cut exactly as before; the tolerance is
for the empty index and nothing else. Before 2026-08-18 this case exited 1
after the build, signature, notarization, GitHub Release and scp had all
succeeded, and inside `release.sh all` it silently dropped every component
queued behind it.

**A batch says what it skipped.** `release.sh all` still stops at the first
component that fails — a failure is usually in something the later components
share — but it now ends with a summary naming what was released, what failed,
and what never ran, and still exits non-zero (`tools/batch.sh`):

```
── batch summary ──
   released: cli
   failed: gateway
   never ran: edge agent
   the cut stopped at the first failure — the components above were NOT cut
```

**If you write shell for `release.sh`/`tools/*.sh`: `mapfile`/`readarray` are
not available.** These scripts must run under **bash 3.2** — the version macOS
still ships as `/bin/bash`, and therefore what `/usr/bin/env bash` resolves to on
any operator machine that has not put a newer bash ahead of it on `PATH`. Both
builtins arrived in bash 4. A script that uses either runs clean wherever a newer
bash happens to be first and dies with "command not found" the first time it runs
for real somewhere it is not — and the suite will not catch that, because the
suite runs under whatever bash the developer has. Build an array from command
output with the read-loop idiom `tools/release_origin.sh` and
`tools/release_origin.test.sh` already use
(`while IFS= read -r line; do … done <<EOF ... EOF`) instead.

---

## `dist/.dispatcher/` — a `--dry-run` used to poison the next `--public` cut

**Fixed; recorded because the failure mode was invisible and the trigger was the
recommended workflow.**

The bundled `burrowee` dispatcher is cached under `dist/.dispatcher/<DISP_STAMP>/`,
and `DISP_STAMP` is derived from the dispatcher **source** — not from the signing
mode. Both modes wrote into the same directory, and `build_dispatcher()` reused
whatever was already there on existence alone. So:

```sh
tools/release.sh edge --dry-run     # leaves an AD-HOC signed dispatcher
tools/release.sh edge --public      # reused it, in every component zip
```

Apple's notary rejected the edge zip for `burrowee` — *not signed with a valid
Developer ID certificate*, *no secure timestamp*, *no hardened runtime* — after a
full build and an upload. Nothing earlier said a word.

Two changes close it, and neither needs anything from the operator:

- `build_dispatcher()` **verifies** a cached darwin entry under `--apple`/`--public`
  (`developer_id_signed()`, `tools/apple_sign.sh`) and rebuilds + re-signs when it
  is ad-hoc, unsigned, or unverifiable. Verified rather than partitioned by mode,
  so a wrong-mode artifact is caught whatever put it there.
- Every payload is checked **before it is zipped**
  (`assert_payload_developer_id_signed()`): under `--apple`/`--public`, every
  Mach-O about to ship must carry a Developer ID authority, a Team ID, Apple's
  secure timestamp and the hardened runtime. Seconds, locally, and it covers
  `--apple` without notarization too.

So a `--dry-run` before a real cut is safe, which is the point of having one.
There is no cache to clear by hand: a stale `dist/.dispatcher/<stamp>/` left by an
earlier ad-hoc build is now rebuilt on demand rather than shipped. Deleting it is
harmless but unnecessary.

---

## Cutting when your session is not a desktop session — `tools/release.command`

**A cut needs a desktop session, and only the notarize step says so.**

`rcodesign` is pure userspace and signs in any session. `notarytool` reaches
Apple through CFNetwork/AppSSO, which needs a per-user bootstrap namespace; in a
background/daemon-hosted shell it SIGTRAPs (`EXC_BREAKPOINT`, "API Misuse" in
`AppSSO::shouldManageURL`) with no submission id. `release.sh` can only report
what it got:

```
Conducting pre-submission checks … and initiating connection to the Apple notary service...
✗ notarization not Accepted (status: unknown)
```

That reads like an Apple outage. It is not one — nothing about the key, the
service, or the flow is broken. Check before starting, not after ten minutes of
building and signing:

```sh
launchctl managername      # Aqua = fine · System = will die at notarize
```

`tools/release.command` makes that check the first thing it does, then runs
`release.sh` unmodified. `open` it — LaunchServices starts it in the desktop's
own terminal, which is an Aqua session, with no Apple Events, no TCC prompt and
no sudo:

```sh
cp .release-request.example .release-request     # edit COMPONENTS / FLAGS
open tools/release.command                   # watch .release.log; ends in RELEASE-EXIT:<code>
```

The file is committed `100755`, so there is no `chmod` step — what it needs is
the `.command` extension, so LaunchServices will open it, not the mode bit.

The Aqua check is necessary, not sufficient, so three more refusals sit beside
it and each names itself: **root** (notarization would use root's keychain, not
yours), an **SSH** session (no console security session at all, whatever
`managername` says), and a **non-tty stdin** (whatever started this, it was not
LaunchServices). A daemon shell that re-execs through `launchctl asuser <uid>`
reports Aqua and still fails at notarize — hence the extra three.

Two `open`s cannot interleave: a `.release.lock` directory is taken for the run
and released by the same exit trap that writes the sentinel. Remove it by hand
only when you have established that no cut is live. `.release.log` is **rotated**
rather than truncated — the previous run moves to `.release.log.prev` — so a
refusal three seconds in never destroys the record of the last real cut, and
there is exactly one run per log. `RELEASE_ENV`, `RELEASE_REQUEST` and
`RELEASE_LOG` override the three input/output paths for a run that must not use
the defaults.

The same refusal now guards the other door. `tools/release.sh <comp> --public` is
a documented entry point of its own, and it calls `require_desktop_session()`
(`tools/apple_sign.sh`) before it resolves the Apple account — only when Apple
signing was requested, and never on a `--dry-run`, which does not reach notarize.
`BURROWEE_ALLOW_ANY_SESSION=1` bypasses it. That is for a machine whose session
model this check misreads; it is not an answer to "the check refused me", which
is the cheap version of a failure you would otherwise buy ten minutes later.

**The launcher pushes — `release.sh` still does not.** Each component's
`[RELEASED: <comp>]` marker commit is pushed to `origin/main` before the next
component starts, and that is the only reason a batch can run unattended: by
Residual 2 above, a cut leaves this repo one commit ahead of its remote, and the
release-origin guard then refuses every component queued behind it. The push is
deliberately narrow — it asserts HEAD is on `main` and not detached, over a clean
tree, and, after a fresh fetch at the moment of the push, **exactly one** commit
ahead of `origin/main`, then names its destination as `HEAD:refs/heads/main`
rather than letting `HEAD`'s whole unpushed ancestry ride to whatever branch it
happened to be on. Under `--dry-run` the push path is skipped entirely rather
than trusted to notice it has nothing to do: a dry run makes no marker, so HEAD
is still the *previous* marker and the subject test would have matched it.

**`COMPONENTS="all"` is refused here**, though `release.sh all` is a real
invocation: it cuts every component inside one process with no push between them,
ending on several unpushed markers under a HEAD that reads `[RELEASED: <last>]` —
the exact wedge this file exists to prevent. Unknown component names are refused
the same way. Legal: `cli gateway edge agent relay`.

**Do not** reach for `osascript`-to-Terminal (Apple Events time out, `-1712`),
`sudo launchctl asuser` (needs passwordless sudo), or a different notarization
backend. The first two fail slowly; the third is editing release tooling under
incident pressure.

### Before the first run

The launcher assumes all of the following and fails at whichever one is missing.
Everything here is set up once per machine, and none of it lives in this repo:

- **`~/.agents/local/release.env`** — the machine facts, loaded before anything
  else (contract below).
- **The two Apple config files**, `config/apple-account` and `config/apple-home` —
  gitignored, one line each, no defaults; see "Cutting a public release: the Apple
  environment" at the top of this file for what they hold and why they exist.
- **The `.dp` secrets repo and the age identity that opens it** — the real
  minisign signing key is decrypted from there per cut (`DP_DIR`, `AGE_IDENTITY`;
  `release.sh`'s own header names the defaults).
- **The pre-flight tools, on the `PATH` that `release.env` sets** — `zip`,
  `unzip`, `minisign`, `jq`, `go`, `ghp` (the account-scoped GitHub CLI wrapper),
  the Developer-ID signer, and the `rcodesign` backend behind it.
- **Every component source worktree in the state the release-origin guard
  demands** — the registry main folder for that component, the *primary* checkout
  and not a linked worktree, on `main`, clean including untracked files, and
  exactly in sync with `origin/main`. This is the prerequisite that silently
  blocks most first attempts: it is checked for every tree a cut reads (the
  component, the dispatcher, `edge.web` for edge, and this repo), nothing reports
  it until the cut starts, and a tree that is merely one commit *ahead* fails it
  as hard as a dirty one. `tools/release_origin.sh` is the whole rule.

### `release.env` — names and roles, never values

Not in this repo, and it will not be: this repo is public. It is `.`-sourced
first, before the request file, and it must set:

| Name | Role |
|---|---|
| `PATH` | extended to reach the toolchain — the Developer-ID signer, the `rcodesign` backend behind it, `go`, `minisign`, `jq`, `zip`/`unzip`, `ghp`. The per-directory hook on this tree strips Homebrew from `PATH`, which is why `release.command` calls `git` by absolute path and why putting the rest back is this file's job |
| `MODERNECH_SIGN` | which binary implements Developer-ID signing and notarization; `release.sh` falls back to the name on `PATH`, then `~/bin`, and aborts if neither resolves |
| `BURROWEE_RELEASE_YES` | skips the interactive minor/major bump confirm — an unattended run that bumps anything but a patch hangs on that prompt without it |

Override the file's path with `RELEASE_ENV`. Anything a cut needs that is a
*secret* belongs in the `.dp` repo, not here — this file holds machine layout,
not credentials.

### When it fails

**A batch is not atomic, and the expensive mistake is re-running it unchanged.**
Read the failed run's `.release.log` from the bottom (`.release.log.prev` is the
run before it):

- the closing **`RELEASE-EXIT:<n>`**. It comes from a single EXIT trap rather
  than a line at the end of whichever paths someone remembered, so it also fires
  on Ctrl-C (130), on the Terminal window being closed (129 — SIGHUP, the usual
  way an operator abandons a `.command`), and on `set -u` tripping inside a
  sourced file. A watcher can therefore treat its *absence* as "still running".
- the **`── cut: <comp> ──`** markers, one per component in request order.
  Everything above the last one is a component that finished.

**Components above the failure are PUBLISHED** — tag, GitHub Release, signed
zips, console catalog entry, and a pushed marker. Re-running the same
`.release-request` does not resume: the first already-cut component resolves to
the stamp it just published, whose tag now exists, and the cut is refused there —
never reaching the components that never ran. **Edit `COMPONENTS` down to the
ones that did not run, then re-run.**

The terminal states worth recognising:

| Final line | What it means | What to do |
|---|---|---|
| `✗ <comp> failed (exit <n>) — later components NOT cut` | `release.sh` itself refused or died; the launcher stopped rather than cutting past a fault the later components probably share | fix the cause, drop the already-published components from `COMPONENTS` |
| `✗ marker push failed for <comp>` | the component **is published**; its marker commit exists locally and did not land. This repo is now one commit ahead of `origin/main`, so every later cut — this batch's or next week's — is refused by the release-origin guard until the push succeeds | confirm HEAD is that marker, then `git push origin HEAD:refs/heads/main`, then re-run with the remaining components |
| `✗ expected exactly 1 unpushed commit (the <comp> marker), found <n>` | HEAD is not the single marker the launcher is willing to publish — an earlier marker never pushed, or something else was committed into this repo | read `git log origin/main..HEAD` before pushing anything; do not widen the push to make it pass |
| `✗ <comp> cut left an unclean tree` | the cut ran to completion, so **the release is already live**, but it wrote something it did not commit | inspect the tree; nothing was pushed, so the marker is still local and the guard will block the next cut |
| `✗ <comp>: HEAD is not a [RELEASED: <comp>] marker … yet <n> commit(s) are unpushed` | the cut published something it did not record | inspect before pushing; this case used to print "nothing to push" and exit 0 |
| `→ <comp>: no marker and nothing unpushed` | **not** a failure — Residual 3, a re-cut at an identical stamp, whose marker is already in history | nothing |

## The bootstrap's pinned minisign — bumping it is a module change, not a cut

`tools/modules/install-minisign-common.sh` pins the upstream minisign release
(version + both archive sha256s + upstream's release public key) that the outer
bootstrap installs when a host has no minisign and its package manager cannot
provide one. That pin is what makes the fetched verifier trustworthy — the
bootstrap carries it, and the bootstrap is the install's trust root — so it
moves only by a reviewed edit to that module: follow the "BUMPING THE PIN"
recipe in its header (verify both archives against upstream's key, measure,
update the constants, bump the module version, re-lock, regenerate, run
`tools/test-install-minisign.sh`), land it through a PR, and then sync it into
Clawee and Umbree with `tools/sync-modules.sh`. Nothing in `release.sh` touches
it; a cut simply ships whatever the committed bootstraps carry.

## Go bump and the legacy overlay

`tools/legacy/darwin/` overlays three `crypto/x509` files so the
`darwin-amd64-legacy` target keeps verifying TLS chains with the macOS-10.7+
`SecTrustGetCertificateAtIndex` API instead of the macOS-12-only
`SecTrustCopyCertificateChain` that current Go imports non-lazily. It is
pinned to one Go minor (`tools/legacy/darwin/GO_VERSION`) and guarded by
`tools/legacy/darwin/overlay.test.sh`, which `build.sh` runs before every
`VARIANT=legacy` build: a Go bump — even a patch release — fails that guard
until a human re-derives the three files against the new stdlib and updates
the pin, rather than silently shipping a stale overlay that either doesn't
apply or reintroduces the macOS-12 symbol. Re-deriving the overlay after a Go
bump is not a cut-time task; do it ahead of the bump, not during a release.
Full procedure, the drift guard's guarantees and its two known gaps, and the
condition under which the variant is dropped entirely: see
`tools/legacy/darwin/README.md` → "Go-bump procedure".

---

## Beta channel

`release.sh <comp> --channel beta` cuts from the registry's dedicated beta
worktree, straight to R2, and never touches GitHub. Design:
`docs/specs/2026-08-27-beta-channel-design.md` (burrowee-git/resources).
`--channel` defaults to `stable`; every stable invocation is unaffected.

### Open a cycle

A beta cycle is two files' presence, nothing more — there is no `open` verb:

1. Create the linked worktree the channel is cut from, sibling to the
   registry's main folder: `<code>/beta`, sibling of `<code>/main`, on branch
   `beta`, tracking `origin/beta` (`tools/release_origin.sh`'s
   `beta_worktree_for` derives this path from the registry entry — it is never
   configured separately). Standard `git worktree add` flow, same shape as any
   other linked worktree in this product.
2. In the **release repo**, write `versions/<comp>.beta` — the component's
   beta semver, one line, `MAJOR.MINOR.PATCH`. It must sort strictly above
   `versions/<comp>` (the stable semver): a beta that doesn't read newer than
   its stable sibling would make a beta node's `version` output, and the
   follow-on stable cut, both lie. `tools/version.sh <comp> --channel beta
   --bump-minor` (or `--bump-patch`) against a starting value of the current
   stable's next minor, patch 0, is the usual opener; `resolve_comp_stamp`
   refuses at cut time (`--assert-beta-above-stable`) if this isn't true.
3. Commit `versions/<comp>.beta`. There is nothing else to stage — the
   `.beta.stamp` companion file doesn't exist yet; the first cut writes it.

### Cut

`bash tools/release.sh <comp> --channel beta --public [--dry-run]`. `--public`
is **still required** — a beta becomes publicly installable the moment the
console promotes it, so Developer-ID signing, notarization and the CVE gate
apply exactly as they do to a stable cut. The empty-`FLAGS` interactive prompt
is unchanged. What it does, once built/signed/notarized:

- **No** git tag, **no** GitHub Release — `gh_release_publish` is skipped
  entirely (see `do_release`'s `CHANNEL=beta` branch).
- Uploads the five platform zips + `SHA256SUMS.txt(.minisig)` to R2 under
  **`<comp>/beta/<stamp>/`** (`register publish-dir --channel beta`), then
  writes `<comp>/beta/latest.json` last, once every artifact is up. Five,
  not four: every public component ships `darwin-amd64-legacy` alongside
  the four base platforms (`ships_target` excludes it for relay only).

  **The `beta/` segment is the layout, not a decoration.** A beta stamp
  used to sit at `<comp>/<stamp>/`, interleaved with the stable stamps,
  which is why nothing could bound it: the stable retention pass skipped
  it (the stamp reads `beta`) and no beta pass could list it (there was no
  prefix to list). Every expression of the layout comes from one place,
  `register.KeyPrefix(comp, channel)` — `publish-dir`, `prune`, the
  manifest writer, and `release.sh` via the `key-prefix` verb. Nothing
  rebuilds the string in shell.

  Relay is the same shape on both channels: `relay/<stamp>/` for stable,
  `relay/beta/<stamp>/` for beta, via `register publish-relay --channel`.
- Regenerates the bootstraps (`gen-bootstraps.sh`, idempotent — it renders
  every channel's twin on every invocation, stable and beta both) and scps
  `<comp>/beta.install.sh` + `beta.upgrade.sh` (+ `beta.updater.install.sh`
  for edge/gateway) to the static host, same as a stable cut ships
  `<comp>/install.sh`.
- Marker commit `[RELEASED: <comp> beta] <date> <stamp> (private)` —
  `tools/release.command`'s push loop matches this subject alongside the
  stable `[RELEASED: <comp>]` one, so a batched beta cut through
  `release.command` still pushes its marker before the next component starts.
- Registers a `staged`, `channel=beta` row with the console (R2 keys, no
  `github_release`), then — **only if that registration succeeded** —
  drains retention for real, both surfaces, right here at cut time (see
  below for why beta's "publish" moment is the cut itself, not a later
  console step, and why the drain is conditional).

**Retention now drains automatically at the five points below.** Every
component and every channel is covered on the surface that actually holds
its artifacts, with two things named rather than glossed:

- **One surface is still report-only, by design** — a plain stable cut's
  own GitHub tail. Named in full after the list.
- **R2 for a stable PUBLIC component is drained at console-promote, not at
  its cut** — because a stable cut does not put it in R2 at all; the
  promote does (`release.sh publish`). "Every channel" therefore means
  every channel is drained at the point where its bytes become reachable,
  which is a different point per channel, not that every site drains
  everything.

Relay is R2-only on both channels, so it has no GitHub half to miss. And
`publish --comp all` no longer prunes relay: it publishes cli/gateway/edge/
agent, so draining relay there was draining a component the command had not
touched. Relay's own cut drains it, and the nightly agent backstops it.

Until this change, every retention surface — R2 objects and
GitHub tags, stable and beta alike — only ever *reported*: `register prune` and
`tools/prune-releases.sh` printed what was over the keep limit, and an
operator was expected to re-run them with `--execute` as a separate
deploy-phase step. That step went unrun, on both brands, for months — by
the time it surfaced, R2 held 27.3 GB and 6.5 GB of artifacts no installer
could reach. A control nobody executes is not a control.

The fix reaches five call sites, one per place a release's artifacts become
safely reachable:

- **Stable console-promote** — `tools/release.sh publish <comp>`, the
  helper that copies an already-public GitHub Release's binaries into R2
  (`register publish`, `internal/register/publish.go`; the `publish` branch
  near the top of `release.sh`). The moment that R2 push succeeds, it runs
  `register prune --comp <c> --channel stable --execute` for each component
  and `CHANNEL=stable tools/prune-releases.sh --execute` for real.
  `register publish` only ever resolves the *current stable* catalog row,
  so this site is stable-only — a beta row never reaches it, and both calls
  say `stable` as a literal rather than reading `CHANNEL` out of the
  environment. `--comp all` expands to `PUBLIC_COMPONENTS`
  (cli/gateway/edge/agent) on **both** surfaces, not just GitHub: `prune
  --comp all` includes relay, which this command never publishes.
- **A beta cut** (`do_release`'s `CHANNEL=beta` branch, above) — unlike
  stable, a beta cut's R2 upload *is* the moment its artifacts become
  reachable; there is no separate promote-to-R2 step to wait for. So the
  drain runs in the same function, at the end: `register prune --comp
  <comp> --channel beta --execute` (R2, keep 1) followed by `CHANNEL=beta
  COMPONENTS=<comp> tools/prune-releases.sh --execute` (GitHub, keep 1).
  The GitHub call closes a gap this RUNBOOK previously documented as having
  **no caller anywhere** — beta git tags (minted only later, when the
  console promotes a row to `public`) used to accumulate silently past 1.
- **A relay cut, either channel** (`do_release_relay`) — relay has no
  GitHub side (R2-only, always), so one call:
  `register prune --comp relay --channel <ch> --execute`, at the end of the
  function. `<ch>` is the cut's own channel, and so is the `publish-relay
  --channel <ch>` upload a few steps above it: relay beta artifacts land at
  `relay/beta/<stamp>/` like any other component's.
- **`--distribute-only <comp> <stamp>`** (`distribute_only`, the second
  half of the split `rkit build` → `release.sh --distribute-only` flow) —
  drains GitHub only, right after `gh_release_publish` creates the tag +
  Release, the self-hosting scp, the marker commit, and `register_staged`
  have all already succeeded — a fact the code now *checks*, see "The drain
  is conditional" below: `CHANNEL=stable COMPONENTS=<comp>
  tools/prune-releases.sh --execute`. `--distribute-only` refuses
  `--channel beta` outright, so `stable` is passed explicitly rather than
  left to the tool's default — it is the only value this path can ever
  have. No R2 call here: `distribute_only` never uploads a public
  component to R2 (that is the stable console-promote site above, a later,
  separate step).
- **`--distribute-only relay <stamp>`** (`distribute_relay`, reached from
  `distribute_only`'s own dispatch) — drains R2 only, at the end of the
  function: `register prune --comp relay --channel stable --execute`. Same
  reasoning as above for passing `stable` explicitly. Relay has no GitHub
  Release to prune here either.

All seven calls across these five sites are `|| true`: a retention failure
must not fail a release whose artifacts are already safely out. (A raw
`grep -- --execute tools/release.sh` now returns more than seven lines: the
skip branches described next *echo* the remediation command for an operator
to copy. Count invocations, not matches.)

**The drain is conditional, not merely last.** For relay (gated on every
channel) and for any component's beta, the console ROW — not the R2 object
— is what makes the bytes installable: an artifact in the bucket with no
catalog row is unreachable. `register_staged` used to warn and return 0
when its console POST failed, so the drains ran regardless. With beta at
keep=1 that meant a cut could upload, fail to register, and then delete the
PREVIOUS beta — leaving the component with no installable beta at all and
no artifact-level rollback (see `keepFor`'s own doc). `register_staged` now
returns non-zero on a failed POST — still non-fatal, every caller swallows
the status — and the four drain sites gate on it. When the gate refuses,
the skip is loud on stderr and prints the exact commands to run after
registering by hand.

Two `register_staged` paths still return 0 without creating a row (the
release identity dir unconfigured; no artifact zips found under the stage
dir). Both are unreachable on the gated paths: a beta or relay cut passes
its own `publish-dir`/`publish-relay` first, which reads `config.toml` from
the same location under `set -e`, and builds every platform zip before
registering. They remain reachable from `--distribute-only` over an
externally staged dir, where the drain is stable-only (keep 3/10, not 1)
and the previous version survives.

**Ambient environment is kept out of every automatic drain.** Both
surfaces read policy from the environment by design — `prune-releases.sh`
takes `KEEP="${KEEP:-10}"`, and `CHANNEL` steers a whole cut — which was
fine while a human typed the command and is not fine now that a cut fires
it. Every automatic `prune-releases.sh --execute` call runs through `env -u
KEEP`, and every automatic `--channel` is a literal, never a `${CHANNEL:-…}`
fallback. A stray `export KEEP=1` or `export CHANNEL=beta` in an operator's
shell cannot steer a destructive drain.

Order is not negotiable at any of them: the drain runs strictly *after* the
upload or publish that makes the new stamp reachable, never before, because
pruning against a count that is about to change is exactly how a retention
pass deletes something it should have kept. None reaches a `--dry-run`
invocation — each sits past its function's own
`if [ "${DRY_RUN}" = 1 ]; then ...; return 0; fi` (or, for
`distribute_only`/`distribute_relay`, past every precondition check that
runs ahead of that same early return), which reports the would-be plan and
returns before any upload or publish happens — confirmed by running all
six shapes for real (`--dry-run`, never `--execute`, never `--public`):
plain stable and beta cuts of a public component and of relay, plus a
`rkit build --dry-run`-staged `--distribute-only` of both a public
component and relay. Every one printed only its pre-existing `would:`
line, if it had one, and none reached the new `(applying)` text or
invoked a prune tool. Two drains have MOVED since those runs —
`do_release_relay`'s and `distribute_relay`'s, from just after their upload
to the end of the function, so the registration gate above could exist —
and both still sit past the same `DRY_RUN` early return; that was
re-confirmed by reading the control flow, not by re-running the six shapes.

The nightly `com.jc.r2-cleanup` launchd agent remains the net for a release
that fails, or is interrupted, before its own drain completes — **and it is
now a net for beta too.** `~/Workstation/Runtime/r2-cleanup.sh` used to run
a single `register prune --comp all` with no `--channel`; `prune` defaults
to stable, so nothing on a schedule had ever listed a `<comp>/beta/` prefix.
It now runs both channels, mirroring the GitHub half in
`github-cleanup.sh`, which already did. (Those scripts are machine-local
orchestration, not part of this repo — they own no keep counts, only the
schedule.)

**One report-only site remains, by design, not by omission.** A plain
stable cut's own tail (`do_release`, past `gh_release_publish`) still only
*reports* GitHub retention at cut time — it does not drain. This is
deliberate, not a leftover gap: at cut time the new tag is not yet
console-promoted, so pruning GitHub tags there would be pruning while the
cut's own artifact is mid-flight, the same ordering hazard the other five
sites exist to avoid. That component's GitHub retention still drains for
real, just later — at the stable console-promote site above, the first
time `tools/release.sh publish <comp>` runs for it. Nothing about this
path is manual-only forever; it is manual **between** a cut and its
promote, same as it always was.

The manual commands below still work for every surface, and remain the
only way to drain the one report-only site above out-of-band (e.g. between
a cut and its promote). For every other path they are no longer a required
deploy-phase step — reach for them only for an out-of-band drain (a
keep-count change, or cleaning up without cutting or promoting anything):

```
register prune --comp <comp> --channel <stable|beta> --execute   # R2 drain
CHANNEL=<stable|beta> tools/prune-releases.sh              # GitHub report (default)
CHANNEL=<stable|beta> tools/prune-releases.sh --execute    # GitHub drain
```

Every cut of a **public** component — a stable full cut, `--distribute-only`,
or a beta cut — always re-runs `gen-bootstraps.sh` (it renders every
channel's bootstrap for every `PUBLIC_COMPONENTS` component on every
invocation, not only a beta cut's or only the component being cut), so it
re-renders `beta.*.sh` for a component whose cycle is open, or deletes it
the first time one runs after that component's cycle has been closed —
possibly a DIFFERENT component from the one this cut is for. Whichever cut
is running **stages** that outcome for every `PUBLIC_COMPONENTS` directory,
not only its own, into its own marker commit — so the working tree is
always clean after any cut — but it does **not ship** the result: scp to
the static host only happens from two sites total, `do_release`'s own
`CHANNEL=beta` branch (a real beta cut shipping its own bootstrap) and
`--distribute-only` (which re-ships whatever `beta.*.sh` currently exist,
since it is always a stable republish). A plain stable cut of a component
with an open (or just-closed) beta cycle therefore commits the twins'
current state but does not push it to the host — the served copy catches
up on the next beta cut or `--distribute-only` run for that component.

`--distribute-only` refuses `--channel beta` outright (`✗ --distribute-only is
a stable-channel verb; a beta cut uploads to R2 in one step`) — it re-publishes
an already-staged, already-GitHub-released component, which a beta cut never
produces.

### `latest.json` — the per-channel pointer in the bucket

Every `publish-dir` / `publish-relay` writes one more object after the
artifacts: **`<comp>/latest.json`** on stable, **`<comp>/beta/latest.json`**
on beta (`register.WriteLatest`, keyed off the same
`register.KeyPrefix(comp, channel)` as everything else). It names the stamp,
the semver, and the zip filenames of that channel's newest publish.

Three things to know about it when you are looking at the bucket:

- **It is written LAST, on purpose.** It is the pointer that makes a stamp
  discoverable, so it must never name artifacts that are not uploaded yet.
  A `publish-dir` that aborts mid-upload leaves the previous pointer intact.
- **One per channel, never shared.** A beta publish writes only
  `<comp>/beta/latest.json`; it must not touch `<comp>/latest.json`, which
  is the stable pointer. Relay is the same:
  `relay/latest.json` vs `relay/beta/latest.json`. (This was the C-grade
  defect the branch's final review caught — `publish-relay` hardcoded the
  stable channel, so a relay beta cut overwrote the stable pointer with a
  beta stamp. `TestPublishFromDirRelayBetaUsesBetaPrefix` now pins it.)
- **It is not what the console reads.** The console has its own catalog row
  and writes `<comp>/latest.beta.json` on promote (below). `latest.json` is
  the bucket's own record of what the last publish put there.

`prune` never deletes it: it lists a channel's prefix and drops whole
version directories, and `latest.json` is not one.

### Migrating the pre-`beta/` layout — `tools/migrate-beta-layout.sh`

Beta stamps cut before this branch sit at the old flat `<comp>/<stamp>/`,
where no retention pass can reach them (the stable pass skips a stamp
reading `beta`; the beta pass lists `<comp>/beta/` and never sees them).
`tools/migrate-beta-layout.sh` moves them, using two register verbs:
`fetch-dir` reads a flat `<comp>/<stamp>/` prefix back out of R2 into a
local dir — the only way to re-key an artifact without rebuilding it — and
`publish-dir --channel beta` writes it to `<comp>/beta/<stamp>/`.

- **Dry-run by default.** Without `--execute` it prints the would-fetch and
  would-publish lines and makes **no** R2 call at all, credentialed or
  otherwise — both verbs sit inside the single `--execute` branch.
- **One-time, with the three stamps hardcoded** (`edge`, `gateway`, `relay`,
  as cut on 2026-08-28). It is not a mode of the retention pass and takes no
  component argument. Delete the script once the migration is confirmed.
- **It is an operator step, not part of any cut.** Nothing in `release.sh`
  calls it. It expects `dist/.tools/burrowee-release-register` to exist —
  a cut builds it, or `go build -o dist/.tools/burrowee-release-register
  ./cmd/burrowee-release-register`.
- **It copies; it does not sweep.** The old flat keys stay where they are
  after a successful run. Order is not negotiable, and the script's own
  header says it: copy → repoint the console rows → verify → only then
  delete the old keys. Deleting before repointing takes the artifacts out
  from under any host currently running that beta.

### What the console does on promote

Promoting a `staged`, `channel=beta` row is the **mirror** of a stable
promote: stable moves GitHub → R2, beta moves **R2 → GitHub**. The console
verifies the stamp's R2 objects (the platform zips + `SHA256SUMS.txt` +
`.minisig`, now under `<comp>/beta/<stamp>/`) are complete and
checksum-clean, creates a **prerelease** GitHub Release `<comp>/<stamp>` on
`burrowee-git/release` streaming the assets from R2, flips the row to
`public` (current within `(component, beta)`), and writes
`<comp>/latest.beta.json` to R2. From that moment `beta.install.sh` resolves
it and push / `update --auto` can reach it. Relay (gated on every channel)
skips the GitHub half — its beta promote is the DB flip plus
`latest.beta.json`. None of this runs from `release.sh`; it is entirely a
console operation, out of scope for a cut.

### Close a cycle

There is no `close` verb either — closing is deleting the two files that mean
"a cycle is open":

1. `git rm versions/<comp>.beta versions/<comp>.beta.stamp` in the release
   repo, commit. The next `gen-bootstraps.sh` run (the next stable cut of any
   public component, or a manual `bash tools/gen-bootstraps.sh`) sees the
   `.beta.stamp` file gone and **sweeps** `<comp>/beta.*.sh` **locally** —
   deletes the file from the working tree, and the NEXT cut — of ANY
   **public** component, stable full cut, `--distribute-only`, or beta —
   **stages**
   that deletion (every `PUBLIC_COMPONENTS` directory, not only its own)
   into its own marker commit (so the working tree stays clean — see the
   note in "Cut" above). Nothing in
   `release.sh` ever deletes a file on the release **host**: every scp site
   here only uploads files that still exist locally, so removing the local
   copy does not touch the served one. Concretely, `<comp>/beta.*.sh` stays
   live at `release.burrowee.com/<comp>/<beta.*.sh>` and keeps **resolving
   and installing the last public beta**, exactly as it did before the cycle
   closed — spec §3 keeps beta tags on GitHub as history, so there is
   something for it to resolve to, **indefinitely**, for as long as anyone
   still has or finds that URL. Nobody *advertises* the link once the cycle
   is closed, but "not advertised" is not "not live" — an operator must
   remove the served file by hand, over ssh, if the closed cycle's public
   beta must actually stop being installable rather than merely stop being
   pointed at.
2. The beta worktree is permanent — it is NOT removed at release (see beta.md)
   (standard worktree teardown — nothing beta-specific about the removal
   itself).
3. Any `staged`/`public` beta rows already in the console catalog are left
   alone — closing a cycle is a release-repo/host-side action; yanking or
   otherwise retiring already-shipped beta releases is a separate, deliberate
   console operation.

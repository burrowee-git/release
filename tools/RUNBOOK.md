# Operator runbook notes

Operator-only. Not needed to contribute code — see `CLAUDE.md` → "Scope of this
manual". Each note records a hazard that the tooling does **not** prevent.

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

`tools/release.sh` keeps the operator-machine default for `APPLE_HOME` (it is
operator tooling, which is where machine layout belongs) and hard-fails the same
way on a missing plugin folder.

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

`assert_cut_origin`'s clean-tree check (`tools/cut_origin.sh`) tolerates
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
it here.

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

**If you write shell for `release.sh`/`tools/*.sh`: `mapfile`/`readarray` do
not exist here.** `/usr/bin/env bash` on this machine resolves to macOS's
system bash, 3.2.57 — there is no Homebrew bash on `PATH`, hooked or not — and
both are bash-4+ builtins. A script that uses either will run clean under a
newer bash on someone else's machine and crash with "command not found" the
first time it runs for real here. Build an array from command output with the
read-loop idiom `tools/cut_origin.sh` and `tools/cut_origin.test.sh` already
use (`while IFS= read -r line; do … done <<EOF ... EOF`) instead.

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

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

## `versions/burrowee.stamp` — the dispatcher-stamp freeze record

Records the last dispatcher stamp actually used, so `resolve_disp_stamp()`
(in `release.sh`) reuses it verbatim — date frozen — across cuts where the
`burrowee` dispatcher source hasn't changed, instead of re-dating it every
cut. A cut that aborts before its `[RELEASED]` marker commit has its staged
write to this file auto-reverted (`revert_dispatcher_version()`, the same
EXIT/INT/TERM trap that reverts `versions/burrowee`) — don't hand-edit it to
"fix" a dirty tree after a failed cut; re-running the cut is enough.

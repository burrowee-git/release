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

| Variable / file | Meaning |
|---|---|
| `config/apple-account` | one line: the account plugin folder name. Overridden by `$APPLE_ACCOUNT`. |
| `APPLE_HOME` | **absolute** path to the directory holding one folder per Apple account. **No default** — the repo is public, so no operator's machine layout is baked into its source. |
| `APPLE_ACCOUNT_DIR` | that account's folder directly; set it and the two above are not consulted. |

```sh
export APPLE_HOME="$HOME/Workstation/Apple"      # your own layout
rkit build --component gateway --public --sign-key …
```

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

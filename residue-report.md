# Guard-work residue — eight items

Branch `guard-modes` in both repos.

- release (`/Volumes/MacintoshED/Workstation/Coding/Burrowee/release/code/.worktrees/guard-modes`), off `main` at `428f8c9`
- gateway (`/Volumes/MacintoshED/Workstation/Coding/Burrowee/gateway/code/.worktrees/guard-modes`), off `beta` at `ab8a526`

Every test run in this report was executed on `burrowee-ci` over ssh, never on the
workstation. Shell suites were run under both `sh` and `dash`.

**Phase vocabulary: unchanged.** The four terminal tokens are still
`ok · rolled-back · aborted · failed`, and `TestGuardStatusEveryPhaseIsRecognised`
walks the same set. Item 1 reworded a summary rather than adding a fifth token; the
justification is below.

---

## Item 1 — `guardPhaseSummary("failed")` was wrong on one of its two paths

**Repo:** gateway (`cmd/burrowee-gateway-cli/guard_status.go`), plus a
vocabulary-alignment change in release.

**What the two paths are.** `inner/gateway/guard.sh`'s `rollback()` writes `failed`
twice:

1. the tail of the function — the previous install *was* restored,
   `restart_service` ran, `verify_serving` timed out. "The rollback itself did not
   come up" is exactly right there;
2. the empty-snapshot arm reached with `RESTART_ATTEMPTED=1` — a fresh host took
   the normal accepted-consent path, the new build was started, it never reported
   its version, and the snapshot held no previous install. **Nothing was rolled
   back**, because there was nothing to roll back to.

Both rendered `"the rollback itself did not come up — this host needs hands"`, so
an operator on the second path was sent looking for a restore that never happened
and for a previous build that never existed on their machine.

**The decision: reword, no new token.** Of the three options in the brief:

- *A new phase token* would put the same vocabulary in two repos, add a row to
  `TestGuardStatusEveryPhaseIsRecognised`, and buy a distinction the operator
  already has on screen. A caller branching on `$?` gets the same `2` either way
  (both paths mean "not serving, and the guard could not fix it"), and both need
  the same thing from a human. It is exactly the case `guardExitCode`'s own header
  argues against for `aborted` vs `rolled-back`, inverted: there the *prose* was
  the discriminator worth having; here the prose cannot be, because there are two
  writers behind one token.
- *Leaning on the guard log alone* is what the fix does for the which-door
  question — `guard-status` prints the tail directly beneath the summary, and each
  of the two `FAILED —` lines names its own path in full — but the summary itself
  still had to stop asserting the rollback.
- *Rewording* is what shipped. The new line says the one thing true of both
  writers:

  > `the host is not serving and the guard could not get it serving — this needs hands`

**Kept in step across repos.** `install.sh`'s `reattach` printed the identical
false claim from its own `failed` arm, and two `guard.sh` comments quoted the old
sentence as the phase's meaning. All three now carry the new wording. Nothing else
in the guard's vocabulary moved.

**Covering test.** `TestGuardFailedSummaryClaimsNoRollback`
(`cmd/burrowee-gateway-cli/guard_status_test.go`). Deliberately a *negative*
check — pinning the exact sentence would fail on any rewording, including a better
one; what must not come back is the claim in any spelling. It forbids
`rollback`/`rolled back`/`restored`/`previous`, and still requires the two halves
an operator needs (`not serving`, `hands`).

**Mutation proof.** Restored the old string in `guard_status.go`:

```
--- FAIL: TestGuardFailedSummaryClaimsNoRollback (0.00s)
    guard_status_test.go:153: guardPhaseSummary("failed") = "the rollback itself did not come up — this host needs hands" — it names "rollback", but one of the two guard paths that write this phase restored nothing and attempted no rollback
    guard_status_test.go:161: ... it no longer says "not serving", and a `failed` host needs both halves
```

---

## Item 2 — the install-side snapshot question crossed a privilege boundary

**Repo:** release (`inner/gateway/install.sh`, `inner/gateway/guard.sh`,
`tools/guard-rollback.test.sh`).

**The defect.** `txn_begin` creates the transaction root-owned `0700`, and
`install.sh` is routinely entered by an unprivileged shell that elevates per
command — which is the whole reason `txn_read_file` / `txn_list_dir` /
`txn_file_exists` exist. The install-side `snapshot_has_binaries` used none of
them: a bare `[ -d "$1/bin" ]` and a glob. On a host whose sudoers refuses every
`sudo -n` (`timestamp_timeout=0`) it saw nothing whatever was really in the
snapshot, so `abort_install` printed

> `this host had no previous gateway install ... the host is as it was found`

— a fact about the operator's machine that the shell had not established and could
not have — and recorded `aborted` for `guard-status` to repeat.

**The fix.** The predicate becomes `snapshot_binaries_state`, three-valued over
`txn_list_dir`:

| answer | meaning |
|---|---|
| `some` | the snapshot holds at least one previous binary |
| `none` | it was **read**, and holds none — the empty shell a fresh host produces |
| `unknown` | this shell cannot see into the transaction at all |

`none` and `unknown` are told apart by the **snapshot directory itself**, which is
a discriminator the installer guarantees rather than hopes for: `txn_begin` creates
`snapshot/bin` and `snapshot/units` before anything else, so a snapshot dir that
lists as empty is not a fresh host — it is a shell that cannot read the directory.
That is the same shape `guard_prove_armed` already uses `installer.pid` for, and
for the same reason: a file that certainly exists is what turns an empty answer
into evidence.

`abort_install` becomes three arms. `some` and `none` are unchanged. The
`unknown` arm:

- describes what was **observed** (the tree is root-owned 0700, this shell is not
  root, its `sudo -n` was refused) rather than what is true of the host;
- restores nothing — there is nothing it could read to restore;
- writes **no terminal phase**. `aborted` there would record "there was no previous
  install" as a *finding*, in the one direction that costs something: an operator
  who has one and now believes this run established they do not. A transaction left
  un-finalised reads as unfinished, which is what it is.
- points at `sudo ls -l $TXN_DIR/snapshot/bin`.

**Re-scoping the pin — and why the pin was not dropped.** Both files already
recorded that byte-identity stood in the way of exactly this fix. The duplication
ends rather than being re-pinned: the guard is execed **as root** by
launchd/systemd, so its two lines are a complete answer there, it has no
elevated-read helper, and giving the rollback path a second file it must find is a
new way for a rollback to fail. Two readers with genuinely different powers get two
predicates.

Dropping the check entirely would have been wrong: the thing the pin was really
protecting is not the bytes but the **verdict** — `rollback()` and `abort_install`
must never report opposite things about one host. So
`t_snapshot_binaries_predicates_agree` now extracts both function bodies (plus the
real `txn_list_dir`), sources each into its own subshell, and:

- drives both against a *populated* and a *fresh* snapshot and requires the same
  verdict from each, and from both together;
- drives the installer's alone against an **unreadable** snapshot — `chmod 000`
  plus a `sudo` stub that refuses, exactly as `timestamp_timeout=0` refuses — and
  requires `unknown`, never `none`. Without that case, a "fix" that simply dropped
  the third state would look green. Skipped under uid 0, where the state cannot
  exist.

One case is deliberately *not* pinned and is documented in the test: a snapshot
directory that is entirely empty (no `bin/`, no `units/`) is something `txn_begin`
never produces, and the two readers legitimately differ there (`none` vs
`unknown`).

**Covering tests.**
`t_snapshot_binaries_predicates_agree` and
`t_abort_install_without_a_guard_cannot_assert_what_it_cannot_read`, both in
`tools/guard-rollback.test.sh`. The second drives the real
`snapshot_binaries_state` through `abort_install` against a real unreadable
transaction *that holds a previous install* — the case the old prose was most wrong
about. Its control is the existing
`t_abort_install_without_a_guard_records_aborted_on_a_virgin_host`: a **readable**
empty snapshot must still say "nothing to restore" and still record `aborted`.

**Mutation proofs.**

*(a) restore the blind two-state predicate:*

```
FAIL: install.sh's snapshot_binaries_state answered 'none' for a snapshot it could not read at all, want unknown — 'none' there is how abort_install came to tell an operator their host had no previous install when it had one it could not see
FAIL: abort_install told the operator their host has no previous install after reading nothing at all — the snapshot it could not see holds one: install: verify_units failed — there is nothing to restore.
FAIL: abort_install did not say that the transaction could not be read: ...
```

*(b) make the two readers disagree on a readable snapshot (`return 1` injected into
guard.sh's predicate):*

```
FAIL: the two readers disagree about a snapshot BOTH can see (populated): guard.sh says 'none', install.sh says 'some' — abort_install and rollback would report opposite things about one host
```

---

## Item 3 — `guard_prove_armed` failed open but left the state lying

**Repo:** release (`inner/gateway/install.sh`, `tools/guard-arm.test.sh`,
`tools/guard-rollback.test.sh`).

**The defect.** On a blind-read host the arm-proof cannot see `guard.pid` or
`guard.log`, so the guard is unproven either way. Continuing is right — a blind read
is not evidence of a dead guard, and refusing costs the operator an install over a
fact nobody established. What was wrong is what it left behind: it returned `0`, so
`guard_arm` set `GUARD_ARMED=1` — an assertion that a guard **exists**.
`abort_install` branches on exactly that, so on a host where the guard really had
died a later verification failure printed *"the guard is undoing this install"*,
restored nothing, restarted nothing, and exited.

**The fix — three values, not two.**

| value | meaning |
|---|---|
| `0` | no guard was armed at all (`BURROWEE_NO_RESTART`, or `guard_arm` refused) |
| `1` | handed to the supervisor **and** proved started |
| `unproven` | the supervisor accepted it; the proof was blind |

`guard_prove_armed` returns **2** for the blind path (`2` = continue, unproven);
`guard_arm` cases on it; the Phases 3-5 gate becomes `!= 0`.

**Why the handoff still fires under `unproven`.** A guard that *did* start is
watching a deadline. Skipping consent/handoff/reattach would print "nothing was
restarted (BURROWEE_NO_RESTART)" while that guard timed out and rolled a perfectly
healthy host back. What `unproven` changes is `abort_install`, not whether the
restart happens.

**What the `unproven` abort arm does** — the two halves that are safe whichever way
the coin landed:

- it **restores in the foreground**. Dead guard: this is the only undo there is.
  Live guard: it restores the same files from the same snapshot moments later, and
  a file copied twice is a file copied.
- it writes **no terminal phase**. `rolled-back`/`aborted` are terminal, and a live
  guard reading a terminal phase takes its "already terminal" arm and stops —
  trading a *possible* stranding for a *certain* one, since restarting is the half
  only the guard can do.
- it states both possibilities and gives the one command that distinguishes them.

**Covering tests.**

- `t_guard_arm_continues_when_the_transaction_cannot_be_read`
  (`tools/guard-arm.test.sh`) — **adapted, not weakened.** It previously asserted
  `GUARD_ARMED=1`. It now asserts the property that assertion stood for (`not 0`,
  so the handoff still fires) *and* the new one (`unproven`, so nothing downstream
  claims a guard exists). Every other check in it is untouched, including its
  control (`t_guard_arm_refuses_when_the_guard_never_starts`: readable transaction,
  dead guard, still a refusal).
- `t_handoff_gate_accepts_an_unproven_guard` (new, structural) — the Phases 3-5
  gate must be spelled `!= 0`.
- `t_abort_install_with_an_unproven_guard_restores_and_leaves_the_phase_open` and
  its control `t_abort_install_with_a_proven_guard_still_defers_everything`
  (`tools/guard-rollback.test.sh`).

**Mutation proofs.**

*(a) `return 2` → `return 0` in `guard_prove_armed`:*

```
FAIL: [Darwin] guard_arm asserted a guard it never saw (GUARD_ARMED must be 'unproven', not '1'): abort_install branches on this and would hand its entire undo to a process that may not exist
FAIL: [Linux] (same)
```

*(b) handoff gate `!= 0` → `= 1`:*

```
FAIL: the handoff gate is spelled 'if [ "$GUARD_ARMED" = 1 ]; then' — it must accept 'unproven' as well as 1, or a guard that started but could not be proven times out and rolls a healthy host back
```

*(c) delete the `unproven` arm from `abort_install`:*

```
FAIL: abort_install marked the transaction 'rolled-back' with an unproven guard — a live guard reading a terminal phase stops without restarting, which is the half this shell cannot do
FAIL: abort_install did not tell the operator the guard was never proven
```

---

## Item 4 — `count_calls` double-printed on no match

**Repo:** release (`tools/guard-rollback.test.sh`).

`grep -c` writes its count **and** exits 1 when that count is zero, so
`grep -c … || printf '0\n'` appended a second zero to the one grep had already
printed. Every caller compares the result to a literal, so the no-match answer
could never equal `0`, and a failure message read `saw 0\n0` — on the two
bootout-counting checks whose entire job is telling one bootout from two.

Now: capture first, substitute only for the cases where grep printed nothing at all
(unreadable or missing file, exit 2).

**Covering test.** `t_count_calls_answers_zero_once` — one match, no match, missing
file.

**Mutation proof.** Restoring the old body:

```
FAIL: count_calls answered 0
tools/guard-rollback.test.sh: 1 check(s) failed
```

(the message truncates at the embedded newline — which is itself the defect on
display.)

---

## Item 5 — the migration probe inherited `SUDO="sudo"`

**Repo:** release (`inner/gateway/install.sh`,
`tools/install-migration-consent.test.sh`).

`should_ask_before_migration` forks the runner with **both streams discarded** and
hands it `SUDO` from `migration_sudo`, which answers a prompting `sudo` whenever
there is a tty. The runner's `receipt_state` really does read root-owned `0600`
receipts through that command, so on an interactive host with a cold sudo timestamp
the probe could raise a bare `Password:` with every line that would explain it
thrown away — and before the consent prompt the probe exists to decide whether to
ask.

`migration_sudo` gains a `probe` mode that never prompts, whatever the tty says. An
explicit caller `SUDO` still wins, in both modes — it is the seam the updater and
this suite reach the runner through, and a probe that ignored it would elevate
differently from the run it speaks for.

**The cost is at most the warning.** A probe that cannot read a receipt exits 12,
which the gate already treats as "cannot tell, proceed exactly as today"; the same
read happens seconds later in the real run, with a normally-warm timestamp and with
`run_root`'s own prose around it.

**Covering tests.** `t_probe_elevation_never_prompts` (driven under `tty_yes`
deliberately — under `tty_no` `migration_sudo` already answers `sudo -n` and the
check would pass against the defect) and `t_probe_honours_an_explicit_sudo`. The
runner stub now logs `SUDO=` alongside the four env values it already recorded.

**Mutation proof.** `migration_sudo probe` → `migration_sudo` at the call site:

```
FAIL: the probe was handed a prompting elevation on an interactive host — its output is discarded, so a password prompt there has nothing to explain it: SUDO=sudo
```

---

## Item 6 — `TestProbeCannotEvaluateIsNotNothingPending` asserted without driving

**Repo:** gateway (`internal/updatescript/migration_probe_test.go`).

The test asserted the probe's `12` and then *stated in a comment* that a real run
refuses with `1` — the one claim a comment cannot pin. Its `10/2` and `11/0`
siblings drive both modes against one host precisely because the property the file
exists for is that the two cannot disagree; `12/1` is the third and last conclusion
the runner can reach, and it was the only one checked by prose.

Both cases now drive the pair, as two subtests. Each reuses **one** fixture host,
probe first — which is safe (`assertProbeTouchedNothing` has already established
the probe wrote nothing, and both `refuse` and `nothing_pending` precede every write
the runner makes) and is also the stronger claim: each pair is genuinely two modes
reading one host, not two fixtures that merely look alike.

**Mutation proof.** `refuse()`'s real-run status `1` → `0` in `migrations/run.sh`:

```
--- FAIL: TestProbeCannotEvaluateIsNotNothingPending/absent-tree-asserted-pre-split
    the real run exit=0, want 1 (refused) — the probe answered 12 (cannot evaluate), so the two disagree
```

The old test passed under that mutation.

---

## Item 7 — stale header clause

**Repo:** release (`tools/install-guard-arms-first.test.sh`).

The header dated the migration's stop as running "before `load_units`" while the
same file asserts `load_units` is not called in the foreground at all — an ordering
against a call the test forbids. It now names the ordering that actually survives
(`guard_arm` before `migrate_from_legacy`) and records why the old spelling went, so
it is not reintroduced.

Comment only; no assertion changed.

---

## Item 8 — record the rejected alternative

**Repo:** release (`inner/gateway/guard.sh`, at the `phase ok` site). **Comment
only — deliberately not implemented.**

The housekeeping window has now been left open twice, and the comment listed only
the two discriminators that share a forever-refusal hazard. The third — a
**time-bounded refusal**: terminal phase **and** a live `guard.pid` **and** no
completion marker **and** a phase file younger than N seconds refuses; older than N,
proceed — does **not** share that hazard, because the age of the phase file only
grows, so a recycled pid stops being able to block anything after N seconds whatever
else is true. A reader weighing the window a third time would reasonably think it
new.

It is now written down as considered and priced out: a fourth marker in the
transaction, a clock read inside `guard_refuse_concurrent`, and an N nobody can
choose honestly without a field report to fit it to — to protect three housekeeping
steps (stale-bin sweep, updater advance, snapshot prune) on a host whose daemon has
**already been verified serving**, and which the second install's own guard re-runs
on its own success. Revisit only if the window is reported hit.

---

## Test results

**release**, on `burrowee-ci`, under both `sh` and `dash` — all ten suites pass:

```
guard-installer-death · guard-rollback · guard-arm · guard-snapshot
install-guard-arms-first · install-migration-consent · install-no-bootout
install-starts-units · install-waits-for-daemon · prefix-gate-drift
```

`go test ./inner/gateway/install_test/` — `ok`.

**gateway**, on `burrowee-ci`:

- `go test ./cmd/burrowee-gateway-cli/` — `ok`.
- `go test ./internal/updatescript/` — 4 failures, **all pre-existing**, none in
  the probe file this work touched:
  `TestUpdateShPlacementElevationStaysNonInteractive` (named in the brief as known),
  `TestUpdateShSignalsAGatewayAtASpacedPath`,
  `TestRunnerRefusesWhileTheGatewayIsStillRunning`,
  `TestRunnerAliveCheckSurvivesASpaceInTheInstallPath`.
  The last three were confirmed by running the same suite against the untouched
  `gateway/code/main` worktree on the same machine, where they fail identically.
  The whole `TestProbe*` group passes.

No existing test was weakened. The one existing assertion that changed
(`t_guard_arm_continues_when_the_transaction_cannot_be_read`, item 3) gained a
check rather than losing one: it now pins both the property its old `GUARD_ARMED=1`
assertion stood for and the property that assertion was hiding.

## Commits

**release** (off `428f8c9`):

```
8ef42e5 test: count_calls printed two zeros on no match                              (4)
f7deb6c test: drop the stale 'before load_units' clause ...                          (7)
a3fa61f guard: record the time-bounded concurrent-refusal variant that was rejected   (8)
2a57655 install: the migration probe must never prompt for a password                (5)
6de1da0 install: keep the failed-phase wording in step with the cli                  (1)
da3f109 install: an unproven guard must not be recorded as an armed one              (3)
85f50dc install: the snapshot question crossed a privilege boundary ...              (2)
```

**gateway** (off `ab8a526`):

```
c3921a7 cli: guard-status told half the failed hosts about a rollback that never ran (1)
276d77b test: pair the probe's 12 with the real run's refusal ...                    (6)
```

## Out of scope, untouched

Mode dispatch; arming a guard anywhere; `BURROWEE_UNITS_ONLY` / `BURROWEE_UPDATE`
guarding; `start_unit_darwin` / `start_unit_linux`. The installer still never
`bootout`s the serve label (`tools/install-no-bootout.test.sh` green).

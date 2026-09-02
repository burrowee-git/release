# `BURROWEE_UNITS_ONLY` — guarding the second install path

Branch `guard-modes` in the release repo
(`/Volumes/MacintoshED/Workstation/Coding/Burrowee/release/code/.worktrees/guard-modes`),
off `main`, on top of the eight residue commits.

**The gateway repo is untouched.** No change was needed there, because the phase
vocabulary did not change — see "Phase vocabulary" below.

Every test run in this report was executed on `burrowee-ci` over ssh, never on the
workstation. Shell suites were run under both `sh` and `dash`.

---

## What was wrong

`burrowee gateway service install` and `doctor --fix` both reach `install.sh`
through `installGatewayUnits` (gateway `cmd/burrowee-gateway-cli/service.go:46`),
in `BURROWEE_UNITS_ONLY` mode. Both are operator verbs, and on a gateway an
operator's session routinely runs **through** the daemon they stop and restart.

That mode had **both** sever points and no protection for either:

| step | what it does |
|---|---|
| `migrate_from_legacy` | runs gateway's `migrations/run.sh`, which stops (and on Darwin unloads) the daemon to copy state at rest |
| `load_units` | restarted the daemon **in this shell's own foreground** |

Whichever fired first took the operator's shell with it, and everything after it
silently never ran. The worst of those was `record_installed_version`: it is what
the *next* run's migration gate reads, so a host severed here kept its migrated
state and its new root-scheme units under an anchor still naming the **old**
release — feeding the wrong floor into every run after it, silently, because the
run that caused it had already vanished.

## What it looks like now

```
assert_can_migrate · check_service_override        <- read-and-refuse, before the transaction
txn_begin · snapshot_take · guard_arm              <- Phase 0
txn_phase replacing                                <- Phase 1
remove_legacy_user_units
should_ask_before_migration -> consent_to_sever migration
migrate_from_legacy · render_units
report_unrecorded_migration · record_installed_version   <- banked before the handoff
verify_units || abort_install                      <- Phase 2 (see below)
txn_phase verified
consent_to_sever restart · txn_phase handoff · reattach  <- Phases 3-5
exit "$_verdict"
```

Same three calls the fresh path makes, the same `guard.sh`, unchanged. **No second
guard implementation and no units-only variant of one.**

---

## Decisions

### `verify_placement` — not called, and the inapplicability is explicit

It is **not called**, and the block says so in a comment plus a `note:` on stderr,
so a later reader cannot mistake a decision for an oversight. Two independent
reasons, both in the code:

1. It walks `$BINS`, which includes `burrowee` and `burrowee-register`. This mode
   places neither — nothing but `ensure_root_exec_surface` places anything at all
   here, and that covers `$ROOT_BINS` only. On a host that legitimately does not
   carry them it would fail an install that did nothing wrong.
2. Its last and strongest check compares each placed binary's sha256 against the
   archive copy `./$b`. There is no archive on this path: `service install` runs a
   kept installer with no bundle beside it. That comparison is skipped by its own
   `[ -f "./$b" ]` guard, so what remains is a walk over files this run never
   touched — **a green tick for work that did not happen**, which is worse than no
   tick. This is the "do not fake a pass" case, and calling it would have been
   exactly that.

**What actually places anything here already verifies itself.** `render_units`
calls `ensure_root_exec_surface`, which places `$ROOT_BINS`, `install.sh` and
`guard.sh` into `$BIN_DIR` and then ends in `verify_root_exec_surface` — the
root-owned, non-root-writable-to-`/` walk over every path a unit is about to name.
It returns non-zero and `render_units` aborts under `set -e` **before a single unit
is written**. Verification by the function that performs the placement is a
stronger arrangement than a second pass over it afterwards.

### `verify_units` — called, unchanged

Units genuinely are rendered on this path, so every check in it applies: both unit
files present, the plist parses (Darwin), and — the load-bearing one — the serve
unit's `ExecStart` target is executable. That last check is precisely the pairing
between the unit just written and the binary `ensure_root_exec_surface` just
placed, which is the one thing a units-only run can get wrong in a way that looks
clean until the restart.

Covered by `t_units_only_verifies_what_it_actually_placed` (guard-rollback), which
asserts both halves: `verify_units` inside the block and before its handoff,
`verify_placement` **not** in the block, and the explaining comment present.

### `check_service_override` stays ahead of `txn_begin`

The fresh path calls it after `guard_arm`, because by then it has already placed
binaries and has no choice. This path does. Both `assert_can_migrate` and
`check_service_override` are read-and-refuse: they inspect what is on disk and
either return or exit, writing nothing. Run before the transaction exists, a
refusal costs a snapshot that was never taken and a guard that was never armed.
Run after, the same refusal exits at phase `replacing` and the guard's
installer-died branch "rolls back" a host on which nothing was done.

### Where each tail step went

| step | before | now | why |
|---|---|---|---|
| `report_unrecorded_migration` | after `load_units` | **before the handoff** | a severed session skipped it |
| `record_installed_version` | after `load_units` | **before the handoff** | the anchor the next run's migration gate reads; a stale one is not a mis-report, it is a wrong floor forever |
| the restart | `load_units`, foreground | **the guard** (`do_restart`) | the foreground restart *is* the sever |
| `sweep_stale_user_bins` | after `load_units` | **the guard**, on the verified-serving branch only (`sweep_stale_bins_via_kept_installer`) | it deletes per-user binaries; until the daemon has restarted onto the loaded units a still-running per-user process may still name one, and on Darwin `KeepAlive.PathState` turns that deletion into a *stop* |
| the updater start | `load_units` | **the guard** (`advance_updater`) | same handoff |
| `finish_with_updater_verdict` | terminal statement | **gone**; `exit "$_verdict"` from `reattach` | the updater start it reported on now happens past the handoff, where this shell cannot observe it; reattach's verdict covers the whole install |

### No doctor tail

The fresh path ends with an unconditional read-only `doctor`. This one does not,
because of its own callers: `doctor --fix` reaches here through
`installGatewayUnits`, so a doctor call at the end of this block would be doctor
running itself as its own last remediation step. Stated in the code.

### `BURROWEE_NO_RESTART`

Reads the same as on the fresh path: `guard_arm` returns without arming, nothing is
handed off, the units are rendered on disk and **not loaded**.

That is a *behaviour change* on this path, and it is a correction. The old
units-only behaviour went through `load_units`' staging branch — a Darwin
`bootstrap` of each label, a Linux `enable` without `--now` — which is a **weaker**
promise than the flag makes: the serve plist this installer writes is `RunAtLoad`,
so a `bootstrap` of a label the host does not already hold **starts the daemon**.
An operator who set the flag because a start was unacceptable got one anyway, on
exactly the fresh host where the flag is most likely to be set. `guard_arm`'s own
header already documented the correct meaning; this path now matches it.

### Consequence worth naming: a missing `guard.sh` now refuses `service install`

`guard_arm` refuses when `guard.sh` is not beside the installer. Units-only now
reaches `guard_arm`, so a `$GW_HOME` or `$BIN_DIR` holding `install.sh` **without**
`guard.sh` is a host on which `service install` and `doctor --fix` refuse, loudly,
rather than installing unguarded. `keep_installer_copy` and
`ensure_root_exec_surface` both place `guard.sh` beside their `install.sh` copies,
so this is reachable only from a mis-assembled bundle or a copy whose `guard.sh`
write failed (which already prints a `note:`). Two stale comments that asserted the
opposite — `keep_installer_copy`'s "units-only … never reaches `guard_arm` at all"
and `ensure_root_exec_surface`'s "must not have `service install` refused over an
artefact that run never arms" — are corrected in place rather than left to mislead.

### `BURROWEE_UPDATE` is not guarded, and now says so

Recorded in `guard.sh`'s header ("WHICH INSTALL MODES ARM A GUARD") with a pointer
beside the update-mode branch in `install.sh`, so the asymmetry is not re-litigated:
that mode restarts nothing (it ends at `BURROWEE_CHANGED` and leaves the restart to
the updater agent), has no operator session to sever, already carries per-binary
rollback, and a guard there would have to restart the process it is running
underneath.

### Dead code kept on purpose

`load_units`, `start_unit_darwin`, `start_unit_linux`, `UPDATER_START_FAILED` and
`finish_with_updater_verdict` are now unreachable on gateway. They are **kept**, and
the top-of-file note (rewritten from "UNREACHABLE FROM THE FRESH-INSTALL PATH" to
"UNREACHABLE FROM EVERY MODE") carries the argument:

* `start_unit_darwin` / `start_unit_linux` are pinned **byte-identical across four
  files** by `tools/prefix-gate-drift.test.sh`, and `load_units` is gateway's only
  caller of the pair — deleting it leaves two functions nothing references, which
  is the state a future reader deletes.
* `tools/install-no-bootout.test.sh` requires a literal `kickstart -k` in this file
  so its "the installer never boots the serve label out" check cannot pass
  vacuously. That literal lives in `start_unit_darwin`.
* edge and relay still restart synchronously through the identical block; gateway's
  copy is what the drift pins compare theirs against.

Removing them is a four-file change with its own brief, not a side-effect of this one.

---

## An unrelated defect this surfaced (fixed, own commit `828b7be`)

`TestInstallShCreatesSystemLogDir` went red with *system data root mode = 0775, want
0700*.

`$SYS_DATA_DIR` holds `gateway.db` and the register/console sockets, and is created
`0700` so a permissive umask cannot leave the store group-readable. That rule lives
in `ensure_system_log_dir` and fires only when *that* function created the root —
correct, because re-tightening a root an operator already has is not the installer's
call. But `txn_begin` now gets there first: `mkdir -p $SYS_DATA_DIR/install/<stamp>`
creates the root as a side effect with the caller's umask, and
`ensure_system_log_dir` then finds it present and rightly leaves it alone.

**This is pre-existing on the fresh path** — it has been true there since the guard
landed — and it went unnoticed because the assertion existed only on the units-only
path. `txn_begin` now applies the same rule to what its own `mkdir` brought into
being, and `TestFreshInstallAlsoLeavesTheDataRootPrivate` is the sibling assertion
the fresh path was missing.

---

## Phase vocabulary: **unchanged**

`armed replacing verified handoff restarting rolling-back ok rolled-back aborted
failed`, exactly as before. Units-only writes `armed`, `replacing`, `verified` and
`handoff` — the same four the fresh path writes.

`replacing` was reused deliberately rather than adding a units-only token. The phase
file is a state machine shared with `guard.sh` and with the cli's
`guardPhaseSummary`, and what that phase means there is "writes are in flight and
the snapshot can undo them", which is exactly true here. That this mode's writes are
units and migrated state rather than binaries is not a distinction anything
downstream acts on: `guard.sh`'s watch loop branches on *terminal vs not*, and
`guardExitCode` on the terminal four. A new token would have bought a word and cost
a two-repo change plus a row in `TestGuardStatusEveryPhaseIsRecognised`.

Consequently **no gateway-repo change was needed**. `go test ./cmd/burrowee-gateway-cli/
-run Guard` on `burrowee-ci` is green against the untouched `guard-modes` branch there.

---

## Go tests adapted, and why each adaptation is honest

Four tests drove `BURROWEE_UNITS_ONLY` *specifically because* it was the last
synchronous restart path — `stale_user_bins_test.go`'s header says so in as many
words. None were deleted or relaxed; each moved to where its claim now lives.

The division applied throughout:

* **"install.sh must hand the restart to the guard and must not perform one
  itself"** — still the Go suite's, still checked there, on both platform shapes.
* **"the guard advances the daemon with the right verb, exactly once, without
  unloading the serve label, unconditionally, and reports when the new build does
  not come up"** — `tools/guard-rollback.test.sh`, against the real `guard.sh`
  driven by a real (fake) supervisor. It *cannot* be checked in the Go suite: those
  stubs **record** the arm and never spawn the guard behind it (`stubInitSystem`'s
  own header gives the reason — a real `systemd-run` would hand a live transient
  unit to the host's own systemd), so the calls those tests used to count are not
  made in that process at all.

| test | became | honest because |
|---|---|---|
| `TestLinuxInstallRestartsTheGatewayDaemon` | `TestLinuxUnitsOnlyIssuesNoRestartOfItsOwn` | same code path, claim **inverted** because the finding inverted it. The remedy for "new files, old process" is still a restart — but not in this shell, which is the connection the operator is reading the output over. The advance itself is `t_guard_ok` / `t_guard_does_not_flap_the_units`. |
| `TestBothPlatformsAdvanceTheDaemon` | `TestBothPlatformsHandTheRestartToTheGuard` | the thing that must hold identically on both branches, and that went wrong once by one platform losing its step, is the handoff now. Two assertions (arm **and** phase), because an arm with no handoff leaves a guard to time out and roll a healthy host back, and a handoff with no arm restarts nothing. |
| `TestLinuxConvergedReinstallStillRestartsTheGatewayDaemon` | `TestLinuxConvergedReinstallStillHandsOff` | the *unconditional-ness* is the point and is kept: a converged re-run, both units reported `(unchanged)`, must still arm and still reach `handoff`. The guard's half is unconditional by construction — `do_restart` takes no did-anything-change argument; `restart_mode` only decides whether launchd must re-read the plist. |
| `TestLinuxReportsAFailedGatewayRestart` | `TestUnitsOnlyReportsAFailedRestartAndStillBanksTheAnchor` | the loud block it asserted is in `load_units`, which nothing calls; asserting that string would be asserting against dead code. The successor is `reattach`, made reachable by `STUB_GUARD_VERDICT`: the arm stub forks a watcher that waits for the installer's own `handoff` and then writes a verdict — the real order of events, which a pre-seeded phase file cannot reproduce because install.sh overwrites it at handoff. |
| `TestInstallShNoRestartStagesWithoutKicking` | `TestInstallShNoRestartStagesWithoutArming` | the old claim was **weaker than the flag**: it permitted the Darwin `bootstrap` that starts a `RunAtLoad` plist. The new one is strictly larger — no guard, no handoff, no supervisor call touching either managed unit, units still rendered. |
| `TestInstallShDefaultPathDoesNotFlapUnits` | `TestInstallShUnitsOnlyTouchesNeitherManagedLabel` | the flap claim moved to `t_guard_does_not_flap_the_units`, **written for this change** so nothing was dropped in the move; what stays in Go is the negative that protects the move. |
| `TestInstallShRunsTheMigrationBeforeLoadingUnits` | `TestInstallShRunsTheMigrationBeforeTheHandoff` | and the ordering is *now actually asserted*. The old test computed `ran` (an index into stdout) and `started` (an index into the stub call log) and compared **neither** — two positions in two streams that cannot be compared even in principle. It passed on any run where the migration ran and the supervisor was called at all, and would have gone on passing vacuously off `remove_legacy_user_units`' own `systemctl --user` line. Both anchors are now in one stream. |
| `TestInstallShConvergesANodeShapedHostUnderEitherStatDialect` | step 3 reads the handoff | the contract ("an install that returns has arranged for the service to be running") is unchanged in substance; the assertion follows it instead of pinning a verb this path no longer issues. `serviceStartCall` is **deleted** — no mode issues that call, so the helper could only be used to assert something false. |
| `TestInstallShLoadsTheSweepFromTheBundleAndCallsIt`, `...IsLoudWhenTheBundleCarriesNoSweepLibrary`, `...ReportsASweepListThatDisagreesWithWhatItInstalls` | driven through `runSweepViaGuardSeam` | this is **not a stand-in for the production call site — it is the production call site**: `BURROWEE_SOURCE_ONLY=1 sh -c '. "$0"; sweep_stale_user_bins' "$BIN_DIR/install.sh"`, byte-for-byte what `guard.sh`'s `sweep_stale_bins_via_kept_installer` runs, including the `$0` steering that makes `$(dirname "$0")/migrations` resolve. Every claim (finds the library, sources it, calls it, with the resolved env; loud on a mis-assembled bundle; reports a list disagreement) is unchanged. |
| `TestInstallShSweepsAfterTheUnitsAreLoaded` | `TestUnitsOnlyDoesNotSweepInItsOwnForeground` | the only genuine loss of a *positive*, and it is covered where it moved, from **both** sides: `t_guard_ok_sweeps_stale_bins` (runs on the verified branch) and the new `t_guard_does_not_sweep_when_the_restart_fails` (does **not** run on the rollback branch — the same safety property stated as the failure it prevents), per platform shape, against the real `guard.sh`. The Go residue is the negative that stops the sweep coming back into the foreground, where it would delete per-user binaries before anything has restarted at all. |

`TestLinuxUpdateModeNeverRestartsTheGateway` gained one assertion rather than losing
any: update mode must arm **no** guard either.

**Nothing was escalated** — every guarantee found a home.

---

## Covering tests added

Shell (`tools/`):

* `install-guard-arms-first.test.sh` — a mode-block line range (everything inside a
  mode block is indented, so the file's column-0 anchors cannot reach it), then:
  `txn_begin` → `snapshot_take` → `guard_arm` before **both** sever points, the
  anchor before the handoff, and **no** `load_units` / no foreground sweep.
* `install-migration-consent.test.sh` — `t_units_only_gate_runs_before_the_migration_and_after_the_guard`
  and `t_units_only_names_the_migration_cause` (migration cause at the stop, restart
  cause before the handoff).
* `guard-rollback.test.sh` — `t_units_only_verifies_what_it_actually_placed` (the
  Phase 2 split, including that the explaining comment exists);
  `t_guard_does_not_sweep_when_the_restart_fails` and
  `t_guard_does_not_flap_the_units`, both per platform shape.

Go (`inner/gateway/install_test/`):

* `TestBothPlatformsHandTheRestartToTheGuard` — units-only arms and hands off, both
  platform shapes.
* `TestUnitsOnlyReportsAFailedRestartAndStillBanksTheAnchor` — the guard's rollback
  verdict is loud and non-zero on this path, and the anchor is present on the run
  that *failed*.
* `TestUnitsOnlySeveredAtTheHandoffStillLeftTheAnchor` — the ordering proof; see
  below.
* `TestInstallShNoRestartStagesWithoutArming` — stages without arming.
* `TestUnitsOnlyDoesNotSweepInItsOwnForeground`.
* `TestFreshInstallAlsoLeavesTheDataRootPrivate`.

Four checks across three suites were **anchored to the wrong handoff** once a second
one existed, and every one would have gone red about the flow it was not looking at
(`t_verify_precedes_handoff`, install-guard-arms-first's record check,
install-waits-for-daemon's enrollment/doctor ordering, and the reconnect-line check,
which took first-with-first and so was satisfied by the units-only pair alone — the
fresh flow could have lost its line entirely and stayed green). All are per-flow now.

`install-waits-for-daemon.test.sh` section 7b's `finish_with_updater_verdict` call
count went `1 → 0`. That is not a dropped assertion: the guarantee it carried
(a failed updater start must not strand the ladder's anchor) is now **stronger** —
the anchor is written before the *handoff*, not merely before the exit status — and
is asserted per flow in `install-guard-arms-first.test.sh`, which owns the handoff
anchor. The `= 0` check itself still forbids a call coming back, because a mode that
ends on that verdict is a mode that restarted in its own foreground.

---

## Mutation proofs

All run on `burrowee-ci`. Each mutation was applied to a copy of the tree, the named
suites run, and the tree restored.

| mutation | caught by |
|---|---|
| drop `guard_arm` from the units-only block | `install-guard-arms-first` (*the units-only block never calls guard_arm — service install and doctor --fix restart the gateway unguarded*), `install-migration-consent`, `TestBothPlatformsHandTheRestartToTheGuard` (both shapes, both assertions), `TestInstallShConvergesANodeShapedHostUnderEitherStatDialect` (all 4 subtests) |
| drop `txn_phase handoff` from the block | `install-guard-arms-first`, `guard-rollback` (*reaches txn_phase handoff 1 time(s), expected 2*), `TestBothPlatformsHandTheRestartToTheGuard`, `TestUnitsOnlyReportsAFailedRestartAndStillBanksTheAnchor`, `TestInstallShRunsTheMigrationBeforeTheHandoff` |
| move `record_installed_version` below the handoff | `install-guard-arms-first`, `TestUnitsOnlySeveredAtTheHandoffStillLeftTheAnchor` |
| add `sweep_stale_user_bins` back to the foreground | `install-guard-arms-first`, `TestUnitsOnlyDoesNotSweepInItsOwnForeground` |
| move the guard's post-success work above `if verify_serving` | `guard-rollback`, both platform shapes, on **both** the sweep and the updater advance |
| drop the units-only migration consent gate | `install-migration-consent` (both the probe call and the cause) |
| swap the migration cause for the restart cause | `install-migration-consent` |
| move `verify_units` below the handoff | `guard-rollback` (*the cheap failure has been moved past the expensive one*) |

### The one that took two attempts, and why it is recorded

`TestUnitsOnlyReportsAFailedRestartAndStillBanksTheAnchor` asserts the anchor is on
disk after a run the guard rolled back. **It does not prove the ordering** — with the
installer still alive, a `record_installed_version` moved *below* `txn_phase handoff`
still executes and still lands. The mutation confirmed it: that test stayed green on
the defect.

The first fix put the kill in the background watcher that polls the phase file. A
second of latency is thousands of statements, so the mutation stayed green there too.

`STUB_GUARD_SEVER=1` now kills the installer **from inside the elevated `mv` that
installs `phase=handoff`** (`writeSudoStub`) — synchronous with the handoff by
construction, which is what a tunnelled operator's session actually is. The pid comes
from the transaction's own `installer.pid`, the same file `guard.sh`'s watch loop
polls for exactly this event, not `$PPID` (which is whichever subshell invoked the
stub). With that, the mutation is caught:

```
--- FAIL: TestUnitsOnlySeveredAtTheHandoffStillLeftTheAnchor/darwin
    a session severed at the handoff left NO version anchor — this host keeps its
    migrated state and new units while the ladder still thinks it is on the old
    release, and every later run gates off the wrong floor
```

---

## Test summary

All on `burrowee-ci`, `sh` **and** `dash` for every shell suite:

```
guard-rollback · guard-arm · guard-snapshot · guard-installer-death
install-guard-arms-first · install-migration-consent · install-no-bootout
install-starts-units · install-waits-for-daemon · prefix-gate-drift     20/20 PASS
go test ./inner/gateway/install_test/                                   ok  13.0s
gateway repo: go test ./cmd/burrowee-gateway-cli/ -run Guard            ok
```

Known and **not** from this work, all verified pre-existing: `cmd/rkit` (4),
`inner/edge/install_test`, `tools/payload.test.sh`, gateway's
`internal/updatescript` failures and `cmd/burrowee-gateway-updater [setup failed]`.
`gofmt -l` flags `update_test.go` only, on a line this change never touched.

## Commits

```
98939cf install: BURROWEE_UNITS_ONLY had both sever points and no guard
3eeee32 test: the shell suites knew about one guarded flow, and there are two now
828b7be install: the transaction created the data root, so nothing set its mode
a570da9 test: four Go tests drove units-only because it was the last synchronous restart
1e4cf1b test: prove the anchor precedes the handoff by severing the session at it
```

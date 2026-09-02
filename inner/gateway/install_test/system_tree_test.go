// system_tree_test.go — the machine-owned tree is CREATED with every level's
// mode stated, and ASSERTED before anything is written into it.
//
// Spec §7 (2026-08-27 v0.3 system-root layout): mode and owner are stated,
// never inherited — not from the umask, not from the archive, not from the
// source file — and the installer asserts what it just built with the same
// predicate the daemon applies, failing the install if any level refuses.
// Three tests, one per inheritance source plus the assertion.
package install_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// runStagedWithUmask is runStaged under `umask <mask>` — the operator's
// shell mask, inherited by every mkdir the installer performs.
func runStagedWithUmask(t *testing.T, script, workDir, home, stubDir, mask string, extraEnv ...string) (string, error) {
	t.Helper()
	cmd := exec.Command("sh", "-c", "umask "+mask+" && exec sh \"$0\"", script)
	cmd.Dir = workDir
	cmd.Env = installShEnv(home, stubDir, extraEnv...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// statedTreeModes is every level of the tree a fresh install creates, with
// the mode install.sh states for it (ensure_system_tree's table).
func statedTreeModes(home string) map[string]os.FileMode {
	return map[string]os.FileMode{
		systemRoot(home):                        0o755,
		binDir(home):                            0o755,
		filepath.Join(systemRoot(home), "etc"):  0o755,
		sysConfigDir(home):                      0o755,
		filepath.Join(systemRoot(home), "var"):  0o755,
		sysDataDir(home):                        0o700,
		filepath.Join(sysDataDir(home), "logs"): 0o700,
	}
}

// seedStatedSystemTree lays out the machine-owned tree the way a completed
// 0.3 install leaves it — every level at its stated mode — for fixtures that
// model an ALREADY-INSTALLED host (update mode, units-only). Against such a
// tree ensure_system_tree has nothing to create or re-mode, so it needs no
// elevation at all — which is the property a test with a refusing `sudo`
// depends on.
func seedStatedSystemTree(t *testing.T, home string) {
	t.Helper()
	for dir, mode := range statedTreeModes(home) {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(dir, mode); err != nil {
			t.Fatal(err)
		}
	}
}

// TestUmask002StillYieldsTheStatedModes — the UMASK trap. `mkdir` under
// sudo creates directories at 0777 &^ umask; an operator with umask 002 gets
// 0775, group-writable, which dir_is_root_secure refuses. Every level must
// come out at its stated mode regardless.
//
// Mutation that reddens it: collapse ensure_system_tree back to a single
// `mkdir -p "$SYS_LOG_DIR"` with no per-level chmod.
func TestUmask002StillYieldsTheStatedModes(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)

	out, err := runStagedWithUmask(t, installShPath(t), staging, home, stub, "002")
	if err != nil {
		t.Fatalf("install under umask 002 failed: %v\n%s", err, out)
	}
	for dir, want := range statedTreeModes(home) {
		st, statErr := os.Stat(dir)
		if statErr != nil {
			t.Errorf("%s was not created: %v", dir, statErr)
			continue
		}
		if got := st.Mode().Perm(); got != want {
			t.Errorf("%s is %04o under umask 002, want %04o — the mode was inherited from the umask, not stated", dir, got, want)
		}
	}
}

// TestAGroupWritablePayloadBinaryStillInstalls0755 — the ARCHIVE trap. unzip
// restores whatever mode the payload recorded, so a binary stored 0775
// extracts 0775 and a copy that preserved it would put a group-writable file
// on the root exec surface. The installed copy must be 0755 whatever the
// staged one was.
//
// Mutation that reddens it: place the binaries with `cp -p` instead of
// `install -m 0755`.
func TestAGroupWritablePayloadBinaryStillInstalls0755(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)
	for _, b := range allBins {
		if err := os.Chmod(filepath.Join(staging, b), 0o775); err != nil {
			t.Fatal(err)
		}
	}

	out, err := runStagedWithUmask(t, installShPath(t), staging, home, stub, "002")
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}
	for _, b := range append(allBins, "install.sh") {
		st, statErr := os.Stat(filepath.Join(binDir(home), b))
		if statErr != nil {
			t.Errorf("%s not placed: %v", b, statErr)
			continue
		}
		if got := st.Mode().Perm(); got != 0o755 {
			t.Errorf("%s installed at %04o, want 0755 — the mode was inherited from the payload", b, got)
		}
	}
}

// statStubRootUIDRealModes is a GNU-dialect stat that reports uid 0 for
// everything and the REAL mode for every path under $SANDBOX (755 for
// anything outside it, so the walk up to / never trips over /tmp's 1777).
// It is what lets an unprivileged test drive the ownership assertion against
// a tree whose modes are genuinely on disk while the uid half — which this
// process cannot fake on a real filesystem — reads as root's.
func statStubRootUIDRealModes(t *testing.T, stubDir, sandbox string) {
	t.Helper()
	realMode := "/usr/bin/stat -c '%a' \"$_p\""
	if runtime.GOOS == "darwin" {
		realMode = "/usr/bin/stat -f '%Lp' \"$_p\""
	}
	body := "#!/bin/sh\n" +
		"[ \"${1:-}\" = -c ] || { echo 'stat: unrecognized option' >&2; exit 1; }\n" +
		"_fmt=\"$2\"; _p=\"$3\"\n" +
		"[ -e \"$_p\" ] || { echo \"stat: cannot statx '$_p': No such file or directory\" >&2; exit 1; }\n" +
		"case \"$_fmt\" in\n" +
		"'%u') echo 0 ;;\n" +
		"'%a') case \"$_p\" in " + shQuote(sandbox) + " | " + shQuote(sandbox) + "/*) " + realMode + " ;; *) echo 755 ;; esac ;;\n" +
		"*) echo 'stat: invalid directive' >&2; exit 1 ;;\n" +
		"esac\n"
	if err := os.WriteFile(filepath.Join(stubDir, "stat"), []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
}

// TestInstallFailsWhenAnAncestorOfTheDataRootIsGroupWritable — the ASSERTION.
// The tree's own levels are re-moded by the installer (they are ours by
// construction), so what can still refuse is the chain ABOVE it — the
// Homebrew shape, one level up. The EXEC chain has a second guard already:
// verify_root_exec_surface walks every ancestor of the binaries a unit names,
// so a group-writable ancestor of $BIN_DIR is refused with or without the
// directory assertion. The STATE chain has no such backstop — nothing walks
// the ancestors of var/gateway but assert_system_tree — so that is the chain
// this test puts on its own sandbox root with a group-writable ancestor. The
// install must fail before its first write, naming the directory, and place
// nothing.
//
// fakeRootUID makes run_root run commands directly and have_real_root
// answer yes, so the assertion is reached; the stat stub reports uid 0 with
// the real modes, so the refusal is about the MODE and nothing else.
//
// Mutation that reddens it: delete the assert_system_tree call from
// ensure_system_tree.
func TestInstallFailsWhenAnAncestorOfTheDataRootIsGroupWritable(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: the files this test places would really be root-owned, so the refusal is unreachable")
	}
	home := t.TempDir()
	stub := stubInitSystem(t)
	staging := t.TempDir()
	seedDummyBins(t, staging)
	fakeRootUID(t, stub)
	statStubRootUIDRealModes(t, stub, home)
	// home/tree2 (0775) / root (0755) / var / gateway: `root` is the level
	// install.sh re-modes as the data chain's own parent; `tree2` is above
	// everything it owns.
	above := filepath.Join(home, "tree2")
	dataRoot := filepath.Join(above, "root", "var", "gateway")
	if err := os.MkdirAll(filepath.Join(above, "root"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(above, 0o775); err != nil {
		t.Fatal(err)
	}

	out, err := runStaged(t, installShPath(t), staging, home, stub, "BURROWEE_SYSTEM_DATA_DIR="+dataRoot)
	if err == nil {
		t.Fatalf("install succeeded with a group-writable ancestor above the data root:\n%s", out)
	}
	if !strings.Contains(out, filepath.Dir(dataRoot)) || !strings.Contains(out, "not root-owned") {
		t.Errorf("the refusal does not name the directory and the reason:\n%s", out)
	}
	if _, statErr := os.Stat(coreUnitPath(home)); statErr == nil {
		t.Errorf("a system unit was written at %s despite the refusal", coreUnitPath(home))
	}
	for _, b := range allBins {
		if _, statErr := os.Stat(filepath.Join(binDir(home), b)); statErr == nil {
			t.Errorf("%s was placed despite the refusal — the assertion ran too late to matter", b)
		}
	}
}

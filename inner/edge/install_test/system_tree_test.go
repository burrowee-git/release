// system_tree_test.go — the machine-owned tree is CREATED with every level's
// mode stated, and ASSERTED before anything is written into it (spec §7 of
// the 2026-08-27 v0.3 system-root layout). Edge's twin of the gateway's
// inner/gateway/install_test/system_tree_test.go, against edge's own leaves:
// etc/edge and var/edge are 0700 (edge publishes nothing to a non-owner),
// every parent 0755.
package install_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// sq single-quotes s for a generated shell stub.
func sq(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// edgeLegacyBinDir is the sandboxed stand-in for /usr/local/bin — the 0.2 exec
// root the sweep reads — which every env builder in this package hands
// install.sh as BURROWEE_LEGACY_BIN_DIR. Never the real directory: the machines
// this suite runs on are live 0.2 hosts.
func edgeLegacyBinDir(home string) string { return filepath.Join(home, "usr-local-bin") }

// statedTreeModes is every level of the tree an install creates inside the
// sandbox, with the mode install.sh states for it (ensure_system_tree). The
// sandbox's three roots hang off sb.home directly, which is therefore the
// sandboxed $SYSTEM_ROOT.
func statedTreeModes(sb sandbox) map[string]os.FileMode {
	return map[string]os.FileMode{
		sb.home:                        0o755,
		sb.sysBinDir:                   0o755,
		filepath.Dir(sb.sysConfigRoot): 0o755,
		sb.sysConfigRoot:               0o755,
		sb.compHome():                  0o700,
		filepath.Dir(sb.sysDataRoot):   0o755,
		sb.sysDataRoot:                 0o755,
		sb.compData():                  0o700,
	}
}

// runUnderUmask runs the staged installer under `umask <mask>` — the
// operator's shell mask, inherited by every mkdir the installer performs.
func (sb sandbox) runUnderUmask(t *testing.T, stub, mask string, extra ...string) (string, error) {
	t.Helper()
	cmd := exec.Command("sh", "-c", "umask "+mask+" && exec sh \"$0\"", stagedInstaller(t, sb.staging))
	cmd.Dir = sb.staging
	cmd.Env = sb.env(stub, extra...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// TestEdgeUmask002StillYieldsTheStatedModes — the UMASK trap. `mkdir` takes
// the process umask; an operator with 002 gets 0775, group-writable, which
// dir_is_root_secure refuses. Every level must come out at its stated mode.
//
// Mutation that reddens it: collapse ensure_system_tree back to `mkdir -p`
// with no per-level chmod.
func TestEdgeUmask002StillYieldsTheStatedModes(t *testing.T) {
	sb := newSandbox(t)
	out, err := sb.runUnderUmask(t, stubRootEnv(t), "002", "STUB_UPDATER_OPTED_IN=1")
	if err != nil {
		t.Fatalf("install under umask 002 failed: %v\n%s", err, out)
	}
	for dir, want := range statedTreeModes(sb) {
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

// TestEdgeAGroupWritablePayloadBinaryStillInstalls0755 — the ARCHIVE trap.
// unzip restores whatever mode the payload recorded; the installed copy must
// be 0755 whatever the staged one was.
//
// Mutation that reddens it: place the binaries with `cp -p` instead of
// `install -m 0755`.
func TestEdgeAGroupWritablePayloadBinaryStillInstalls0755(t *testing.T) {
	sb := newSandbox(t)
	for _, b := range edgeBins {
		if err := os.Chmod(filepath.Join(sb.staging, b), 0o775); err != nil {
			t.Fatal(err)
		}
	}
	out, err := sb.runUnderUmask(t, stubRootEnv(t), "002", "STUB_UPDATER_OPTED_IN=1")
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}
	for _, b := range edgeBins {
		st, statErr := os.Stat(filepath.Join(sb.sysBinDir, b))
		if statErr != nil {
			t.Errorf("%s not placed: %v", b, statErr)
			continue
		}
		if got := st.Mode().Perm(); got != 0o755 {
			t.Errorf("%s installed at %04o, want 0755 — the mode was inherited from the payload", b, got)
		}
	}
}

// edgeStatStubRootUIDRealModes is a GNU-dialect stat reporting uid 0 for
// everything and the REAL mode for every path at or under sandbox (755
// elsewhere, so the walk to / never trips over /tmp's 1777). It is what lets
// an unprivileged test reach the ownership assertion: have_real_root asks
// the filesystem who owns a probe file, and through this stub it is root.
func edgeStatStubRootUIDRealModes(t *testing.T, stubDir, sandbox string) {
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
		"'%a') case \"$_p\" in " + sq(sandbox) + " | " + sq(sandbox) + "/*) " + realMode + " ;; *) echo 755 ;; esac ;;\n" +
		"*) echo 'stat: invalid directive' >&2; exit 1 ;;\n" +
		"esac\n"
	stubBin(t, stubDir, "stat", body)
}

// envReplacing returns sb.env with one KEY= entry replaced — a duplicate key
// in an exec environment is resolved by libc, not Go, so appending would
// leave which value the script sees up to the platform.
func (sb sandbox) envReplacing(stub, key, value string, extra ...string) []string {
	env := sb.env(stub, extra...)
	for i, kv := range env {
		if strings.HasPrefix(kv, key+"=") {
			env[i] = key + "=" + value
		}
	}
	return env
}

// TestEdgeInstallFailsWhenAnAncestorOfTheDataRootIsGroupWritable — the
// ASSERTION. The tree's own levels are re-moded by the installer (they are
// ours by construction), so what can still refuse is the chain ABOVE it. The
// exec chain has a second guard in the units' own root-secure walks; the
// STATE chain has none but assert_system_tree — so that is the chain this
// puts on its own sandbox root with a group-writable ancestor. The install
// must fail before its first write, naming the directory, and place nothing.
//
// Mutation that reddens it: delete the assert_system_tree call from
// ensure_system_tree.
func TestEdgeInstallFailsWhenAnAncestorOfTheDataRootIsGroupWritable(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: the files this test places would really be root-owned, so the refusal is unreachable")
	}
	sb := newSandbox(t)
	stub := stubRootEnv(t)
	edgeStatStubRootUIDRealModes(t, stub, sb.home)
	above := filepath.Join(sb.home, "tree2")
	dataRoot := filepath.Join(above, "root", "var")
	if err := os.MkdirAll(filepath.Join(above, "root"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(above, 0o775); err != nil {
		t.Fatal(err)
	}

	cmd := exec.Command("sh", stagedInstaller(t, sb.staging))
	cmd.Dir = sb.staging
	cmd.Env = sb.envReplacing(stub, "SYS_DATA_ROOT", dataRoot, "STUB_UPDATER_OPTED_IN=1")
	outB, err := cmd.CombinedOutput()
	out := string(outB)
	if err == nil {
		t.Fatalf("install succeeded with a group-writable ancestor above the data root:\n%s", out)
	}
	if !strings.Contains(out, dataRoot) || !strings.Contains(out, "not root-owned") {
		t.Errorf("the refusal does not name the directory and the reason:\n%s", out)
	}
	sb.assertNothingPlaced(t, out)
}

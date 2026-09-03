// path_advice_test.go — the "Next steps" block that REPLACED the
// /usr/local/bin symlinks, for the gateway.
//
// The block's own shape — the four shell renderings, the two ways a subject
// fails to resolve — is a claim of the shared library and is proved once,
// against that library, in inner/edge/install_test/path_advice_test.go. What is
// this file's is the SEAM: does install.sh load the library, call
// render_path_advice with the $BIN_DIR it resolved, and do it as the last thing
// on the success path.
//
// THE FIXTURE IS THE REPO'S OWN SHARED LIBRARY, not one this test wrote. The
// gateway kit ships the GATEWAY repo's copy of lib_stale_user_bins.sh, which is
// not in this repo — but everything between the SHARED SWEEP CONTRACT sentinels
// is byte-identical in the two copies and pinned to one digest in both
// (tools/test-shared-migrations.sh, and the gateway's own suite), and
// render_path_advice lives inside those sentinels. So staging
// inner/_shared/migrations here is not a self-authored stand-in: it is the same
// bytes the gateway's copy is required to carry.
package install_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// stageSharedSweepLibrary lays the repo's own shared sweep library and its
// lib_paths.sh sibling into <dir>/migrations, which is where install.sh's
// stale_sweep_lib resolves them from ($(dirname "$0")/migrations).
//
// lib_paths.sh goes with it because the library sources it for home_of_user
// when the caller has not already defined one — and without it the advice would
// degrade to the generic block for a reason that has nothing to do with the
// code under test.
func stageSharedSweepLibrary(t *testing.T, dir string) {
	t.Helper()
	src, err := filepath.Abs(filepath.Join("..", "..", "_shared", "migrations"))
	if err != nil {
		t.Fatalf("resolve _shared/migrations: %v", err)
	}
	mig := filepath.Join(dir, "migrations")
	if err := os.MkdirAll(mig, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, base := range []string{"lib_stale_user_bins.sh", "lib_paths.sh"} {
		body, readErr := os.ReadFile(filepath.Join(src, base))
		if readErr != nil {
			t.Fatalf("read %s: %v", base, readErr)
		}
		if err := os.WriteFile(filepath.Join(mig, base), body, 0o755); err != nil {
			t.Fatalf("stage %s: %v", base, err)
		}
	}
}

// gatewayPasswdStubs writes the passwd-database half into an existing stub PATH
// dir: getent answers for exactly one account and dscl answers for none, so the
// library's macOS branch cannot reach the real directory service of the machine
// this suite runs on.
func gatewayPasswdStubs(t *testing.T, stub, user, home, shell string) {
	t.Helper()
	getent := "#!/bin/sh\n" +
		"[ \"$1\" = passwd ] || exit 2\n" +
		"case \"$2\" in\n" +
		"'" + user + "') printf '%s:x:1000:1000::%s:%s\\n' \"$2\" '" + home + "' '" + shell + "' ;;\n" +
		"*) exit 2 ;;\n" +
		"esac\n"
	if err := os.WriteFile(filepath.Join(stub, "getent"), []byte(getent), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stub, "dscl"), []byte("#!/bin/sh\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
}

// TestGatewayInstallPrintsThePathAdvice — a full sandboxed install ends by
// naming the exec root and the invoking operator's own profile file.
//
// $SUDO_USER names a seamed account whose home is NOT the sandbox $HOME, which
// under `curl … | sudo sh` is root's: an implementation reading $HOME would
// name the sandbox home, and the assertion on the operator's .zprofile rejects
// that.
//
// Mutation that reddens it: drop the print_path_advice call from install.sh.
func TestGatewayInstallPrintsThePathAdvice(t *testing.T) {
	home := t.TempDir()
	stub := linkingStub(t, home)
	operatorHome := filepath.Join(home, "operator")
	gatewayPasswdStubs(t, stub, "gw-operator", operatorHome, "/bin/zsh")
	staging := t.TempDir()
	seedDummyBins(t, staging)
	stageSharedSweepLibrary(t, staging)

	// The installer must run FROM the bundle: it resolves migrations/ beside its
	// own $0, so the repo's copy would look for a directory that is not there
	// and fall back instead of loading the library staged above.
	out, err := runStaged(t, stageInstaller(t, staging), staging, home, stub, "SUDO_USER=gw-operator")
	if err != nil {
		t.Fatalf("install failed: %v\n%s", err, out)
	}
	assertContains(t, out,
		"==> Next steps",
		"burrowee's commands are in "+binDir(home)+", which is not on your PATH.",
		"    export PATH=\""+binDir(home)+":$PATH\"",
		"    echo 'export PATH=\""+binDir(home)+":$PATH\"' >> "+filepath.Join(operatorHome, ".zprofile"),
		"  Then:  burrowee help",
	)
	if strings.Contains(out, "has no render_path_advice") {
		t.Errorf("install.sh fell back instead of calling the staged library's renderer:\n%s", out)
	}
}

// TestGatewayUpdaterInstallPrintsThePathAdvice — the recovery installer ends
// the same way. It places only burrowee-gateway-updater, which nobody types,
// but it is still an install that leaves an operator at a prompt with an exec
// root on nobody's PATH — and it is the entry point reached precisely when the
// component's normal channel is broken.
//
// Mutation that reddens it: drop the print_path_advice call from
// updater.install.sh.
func TestGatewayUpdaterInstallPrintsThePathAdvice(t *testing.T) {
	f := newUpdaterFixture(t)
	stageSharedMigrations(t, f.staging)
	stageSharedSweepLibrary(t, f.staging)
	operatorHome := filepath.Join(f.home, "operator")
	stub := stubInitSystem(t)
	gatewayPasswdStubs(t, stub, "gw-operator", operatorHome, "/bin/zsh")

	out, err := f.run(t, stub, "SUDO_USER=gw-operator")
	if err != nil {
		t.Fatalf("updater.install.sh failed: %v\n%s", err, out)
	}
	assertContains(t, out,
		"==> Next steps",
		"burrowee's commands are in "+f.sysBinDir+", which is not on your PATH.",
		"    echo 'export PATH=\""+f.sysBinDir+":$PATH\"' >> "+filepath.Join(operatorHome, ".zprofile"),
	)
	if strings.Contains(out, "has no render_path_advice") {
		t.Errorf("updater.install.sh fell back instead of calling the staged library's renderer:\n%s", out)
	}
}

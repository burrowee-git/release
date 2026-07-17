// Package install_test: D3b tests for BURROWEE_UPDATE mode of install.sh.
// Tests verify per-binary sha256 change detection, transactional backup/restore,
// and the BURROWEE_CHANGED=<names> last-line contract.
package install_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// allBins is the full set of binaries declared in BINS inside install.sh.
var allBins = []string{
	"burrowee",
	"burrowee-gateway",
	"burrowee-gateway-cli",
	"burrowee-gateway-console",
	"burrowee-register",
	"burrowee-gateway-updater",
}

// seedInstalled writes each binary name→content into binDir with mode 0755.
func seedInstalled(t *testing.T, binDir string, contents map[string]string) {
	t.Helper()
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatalf("mkdir binDir: %v", err)
	}
	for name, body := range contents {
		p := filepath.Join(binDir, name)
		if err := os.WriteFile(p, []byte(body), 0o755); err != nil {
			t.Fatalf("seed installed %s: %v", name, err)
		}
	}
}

// stageBundle creates a temp directory containing each binary name→content
// and returns that directory (used as cwd when running install.sh).
func stageBundle(t *testing.T, contents map[string]string) string {
	t.Helper()
	staged := t.TempDir()
	for name, body := range contents {
		p := filepath.Join(staged, name)
		if err := os.WriteFile(p, []byte(body), 0o755); err != nil {
			t.Fatalf("stage bundle %s: %v", name, err)
		}
	}
	return staged
}

// readInstalled reads and returns the content of a binary from binDir.
func readInstalled(t *testing.T, binDir, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(binDir, name))
	if err != nil {
		t.Fatalf("readInstalled %s: %v", name, err)
	}
	return string(b)
}

// lastLineWithPrefix finds the last line in output that starts with prefix.
func lastLineWithPrefix(output, prefix string) string {
	lines := strings.Split(strings.TrimRight(output, "\n"), "\n")
	result := ""
	for _, l := range lines {
		if strings.HasPrefix(l, prefix) {
			result = l
		}
	}
	return result
}

// runUpdate runs install.sh in BURROWEE_UPDATE=1 mode with cwd=stageDir.
// env contains extra "KEY=VALUE" strings. scriptArgs are passed as positional
// arguments to the script (e.g. "--version", "v2"). Returns combined output;
// fails the test on non-zero exit.
func runUpdate(t *testing.T, stageDir, home, stubDir string, env []string, scriptArgs ...string) string {
	t.Helper()
	args := append([]string{installShPath(t)}, scriptArgs...)
	cmd := exec.Command("sh", args...)
	cmd.Dir = stageDir
	cmd.Env = installShEnv(home, stubDir, env...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Logf("install.sh output:\n%s", out)
		t.Fatalf("install.sh failed: %v", err)
	}
	return string(out)
}

// runUpdateExpectFail is like runUpdate but expects a non-zero exit.
// Returns combined output without failing the test.
func runUpdateExpectFail(t *testing.T, stageDir, home, stubDir string, env []string, scriptArgs ...string) string {
	t.Helper()
	args := append([]string{installShPath(t)}, scriptArgs...)
	cmd := exec.Command("sh", args...)
	cmd.Dir = stageDir
	cmd.Env = installShEnv(home, stubDir, env...)
	out, _ := cmd.CombinedOutput()
	return string(out)
}

// allBinsContent returns a map of all 5 bins each mapped to the given body.
func allBinsContent(body string) map[string]string {
	m := make(map[string]string, len(allBins))
	for _, b := range allBins {
		m[b] = body
	}
	return m
}

// TestUpdateReplacesOnlyChangedBinaries verifies that when only one binary
// differs (burrowee-gateway), only that binary is replaced; the others stay
// at v1; and BURROWEE_CHANGED= names only that binary.
func TestUpdateReplacesOnlyChangedBinaries(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	binDir := home + "/.local/bin"

	// Pre-install v1 of all 5 bins.
	seedInstalled(t, binDir, allBinsContent("v1-content"))

	// Stage: only burrowee-gateway differs.
	staged := allBinsContent("v1-content")
	staged["burrowee-gateway"] = "v2-content"
	stageDir := stageBundle(t, staged)

	out := runUpdate(t, stageDir, home, stub,
		[]string{"BURROWEE_UPDATE=1"},
		"--version", "v2",
	)

	// burrowee-gateway must be the new content.
	if got := readInstalled(t, binDir, "burrowee-gateway"); got != "v2-content" {
		t.Fatalf("burrowee-gateway not updated: got %q, want v2-content", got)
	}
	// All others must remain at v1.
	for _, b := range allBins {
		if b == "burrowee-gateway" {
			continue
		}
		if got := readInstalled(t, binDir, b); got != "v1-content" {
			t.Fatalf("%s should be unchanged: got %q, want v1-content", b, got)
		}
	}

	// BURROWEE_CHANGED= must be the last occurrence and name only the changed binary.
	line := lastLineWithPrefix(out, "BURROWEE_CHANGED=")
	if line != "BURROWEE_CHANGED=burrowee-gateway" {
		t.Fatalf("change-set = %q, want BURROWEE_CHANGED=burrowee-gateway", line)
	}

	// --version must be recorded in $GW_HOME/.installed-version.
	vf := filepath.Join(home, ".burrowee/gateway/.installed-version")
	vb, err := os.ReadFile(vf)
	if err != nil {
		t.Fatalf("installed-version not written: %v", err)
	}
	if strings.TrimSpace(string(vb)) != "v2" {
		t.Fatalf("installed-version = %q, want v2", string(vb))
	}
}

// TestUpdateAllIdenticalIsNoop verifies that when staged content matches
// installed content for all binaries, no binary is touched and
// BURROWEE_CHANGED= is empty.
func TestUpdateAllIdenticalIsNoop(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	binDir := home + "/.local/bin"

	same := allBinsContent("identical-content")
	seedInstalled(t, binDir, same)
	stageDir := stageBundle(t, same)

	out := runUpdate(t, stageDir, home, stub, []string{"BURROWEE_UPDATE=1"})

	// All binaries must remain unchanged.
	for _, b := range allBins {
		if got := readInstalled(t, binDir, b); got != "identical-content" {
			t.Fatalf("%s modified on no-op update: got %q", b, got)
		}
	}

	// BURROWEE_CHANGED= must appear with an empty value.
	line := lastLineWithPrefix(out, "BURROWEE_CHANGED=")
	if line != "BURROWEE_CHANGED=" {
		t.Fatalf("change-set = %q, want BURROWEE_CHANGED= (empty)", line)
	}
}

// writeLaunchctlStub drops a fake `launchctl` into dir that appends its argv
// to dir/launchctl.calls, so a test can assert whether install.sh restarted
// services.
func writeLaunchctlStub(t *testing.T, dir string) {
	t.Helper()
	stub := "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"" + filepath.Join(dir, "launchctl.calls") + "\"\nexit 0\n"
	if err := os.WriteFile(filepath.Join(dir, "launchctl"), []byte(stub), 0o755); err != nil {
		t.Fatal(err)
	}
}

// TestUpdateModeExcludesUpdaterBinary verifies that a changed
// burrowee-gateway-cli is neither swapped nor named in BURROWEE_CHANGED.
func TestUpdateModeExcludesUpdaterBinary(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	binDir := home + "/.local/bin"

	// Pre-install: burrowee-gateway-cli is OLD, all others at v1.
	installed := allBinsContent("v1-content")
	installed["burrowee-gateway-cli"] = "OLD-CLI"
	seedInstalled(t, binDir, installed)

	// Stage: burrowee-gateway-cli differs (NEW-CLI) and burrowee-gateway differs (v2).
	staged := allBinsContent("v1-content")
	staged["burrowee-gateway-cli"] = "NEW-CLI"
	staged["burrowee-gateway"] = "v2-content"
	stageDir := stageBundle(t, staged)

	out := runUpdate(t, stageDir, home, stub,
		[]string{"BURROWEE_UPDATE=1"},
		"--version", "v2",
	)

	// burrowee-gateway-cli must NOT appear in BURROWEE_CHANGED.
	if got := lastLineWithPrefix(out, "BURROWEE_CHANGED="); strings.Contains(got, "burrowee-gateway-cli") {
		t.Fatalf("update mode must not change burrowee-gateway-cli; got %q", got)
	}

	// burrowee-gateway-cli must NOT be swapped — content stays OLD-CLI.
	cur, err := os.ReadFile(filepath.Join(binDir, "burrowee-gateway-cli"))
	if err != nil {
		t.Fatalf("read burrowee-gateway-cli: %v", err)
	}
	if string(cur) != "OLD-CLI" {
		t.Fatalf("burrowee-gateway-cli was swapped in update mode (got %q)", cur)
	}
}

// TestUpdateModeDoesNotRestartServices verifies that update mode refreshes
// unit FILES but issues no launchctl/systemctl service operations at all —
// no bootout/bootstrap/enable/restart, and no legacy-unit migration (the
// updater restarts the kernel out-of-band; a reload here would bootout the
// running process).
func TestUpdateModeDoesNotRestartServices(t *testing.T) {
	home := t.TempDir()

	// Create a stub dir with a recording launchctl, a recording systemctl,
	// and the pass-through sudo the system unit writes go through.
	stubDir := t.TempDir()
	writeLaunchctlStub(t, stubDir)
	sysctl := "#!/bin/sh\nprintf '%s\\n' \"systemctl $*\" >> \"" + filepath.Join(stubDir, "launchctl.calls") + "\"\nexit 0\n"
	if err := os.WriteFile(filepath.Join(stubDir, "systemctl"), []byte(sysctl), 0o755); err != nil {
		t.Fatal(err)
	}
	writeSudoStub(t, stubDir)

	binDir := home + "/.local/bin"
	seedInstalled(t, binDir, allBinsContent("v1-content"))

	// Stage one changed binary so the script does real work.
	staged := allBinsContent("v1-content")
	staged["burrowee-gateway"] = "v2-content"
	stageDir := stageBundle(t, staged)

	runUpdate(t, stageDir, home, stubDir,
		[]string{"BURROWEE_UPDATE=1"},
	)

	calls, _ := os.ReadFile(filepath.Join(stubDir, "launchctl.calls"))
	callsStr := string(calls)
	for _, verb := range []string{"bootout", "bootstrap", "enable", "restart", "disable"} {
		for _, line := range strings.Split(strings.TrimRight(callsStr, "\n"), "\n") {
			if strings.Contains(line, verb) {
				t.Fatalf("update mode must not touch live services; got call: %q\nall calls:\n%s", line, callsStr)
			}
		}
	}

	// The unit FILES must still have been refreshed.
	unitPath := filepath.Join(launchdDir(home), "com.burrowee.gateway.plist")
	if runtime.GOOS != "darwin" {
		unitPath = filepath.Join(systemdDir(home), "burrowee-gateway.service")
	}
	if _, err := os.Stat(unitPath); err != nil {
		t.Errorf("update mode did not render the system unit file: %v", err)
	}
}

// TestUpdateRollsBackOnFailure verifies that when a binary cannot be placed
// mid-swap, all previously placed (and backed-up) binaries are restored to
// their original content, the script exits non-zero, and no BURROWEE_CHANGED
// line is printed.
//
// Failure injection: inject a stub `install` command (prepended to PATH) that
// succeeds on the first invocation then fails on all subsequent ones. Two
// binaries differ (burrowee-gateway first in BINS order, burrowee-gateway-
// console second) so the first placement succeeds and the second fails,
// triggering rollback of burrowee-gateway back to v1.
func TestUpdateRollsBackOnFailure(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	binDir := home + "/.local/bin"

	// Pre-install v1 of all 5 bins.
	seedInstalled(t, binDir, allBinsContent("v1-content"))

	// Stage: two binaries differ — burrowee-gateway (first in BINS) and
	// burrowee-gateway-console (third in BINS).
	staged := allBinsContent("v1-content")
	staged["burrowee-gateway"] = "gw-v2-content"
	staged["burrowee-gateway-console"] = "console-v2-content"
	stageDir := stageBundle(t, staged)

	// Write a stub `install` into the stub dir. It uses a counter file to
	// succeed on the first call (placing burrowee-gateway) and fail on the
	// second changed binary (burrowee-gateway-console), triggering rollback.
	counterFile := filepath.Join(stub, "install.counter")
	installStub := filepath.Join(stub, "install")
	installStubContent := "#!/bin/sh\n" +
		"count=0\n" +
		"if [ -f \"" + counterFile + "\" ]; then count=$(cat \"" + counterFile + "\"); fi\n" +
		"count=$((count + 1))\n" +
		"printf '%s' \"$count\" > \"" + counterFile + "\"\n" +
		"if [ \"$count\" -gt 1 ]; then exit 1; fi\n" +
		// On first call, perform the actual install: last two args are src and dst.
		"src=\"\"; dst=\"\"\n" +
		"while [ $# -gt 0 ]; do prev=\"$dst\"; dst=\"$1\"; src=\"$prev\"; shift; done\n" +
		"cp \"$src\" \"$dst\" && chmod 0755 \"$dst\"\n"
	if err := os.WriteFile(installStub, []byte(installStubContent), 0o755); err != nil {
		t.Fatalf("write install stub: %v", err)
	}

	out := runUpdateExpectFail(t, stageDir, home, stub,
		[]string{"BURROWEE_UPDATE=1"},
	)

	// burrowee-gateway must be rolled back to its original v1 content.
	if got := readInstalled(t, binDir, "burrowee-gateway"); got != "v1-content" {
		t.Fatalf("burrowee-gateway not rolled back: got %q, want v1-content", got)
	}

	// No BURROWEE_CHANGED= line must appear in the output.
	if line := lastLineWithPrefix(out, "BURROWEE_CHANGED="); line != "" {
		t.Fatalf("BURROWEE_CHANGED line printed on failure: %q", line)
	}
}

// TestUpdateUnitWriteFailurePrintsSudoAdvisory verifies that when the system
// unit content changed but the privileged write fails (no usable sudo), update
// mode prints the needs-sudo advisory instead of a false "service unit:"
// success line, and the binary swap itself still succeeds.
func TestUpdateUnitWriteFailurePrintsSudoAdvisory(t *testing.T) {
	home := t.TempDir()
	stub := stubInitSystem(t)
	binDir := home + "/.local/bin"

	seedInstalled(t, binDir, allBinsContent("v1-content"))
	staged := allBinsContent("v1-content")
	staged["burrowee-gateway"] = "gw-v2-content"
	stageDir := stageBundle(t, staged)

	// No unit file exists in the sandboxed unit dir, so render_units must take
	// the privileged write path — and this sudo always fails.
	failing := "#!/bin/sh\necho \"sudo $*\" >> \"$STUB_LOG\"\nexit 1\n"
	if err := os.WriteFile(filepath.Join(stub, "sudo"), []byte(failing), 0o755); err != nil {
		t.Fatalf("write failing sudo: %v", err)
	}

	out := runUpdate(t, stageDir, home, stub, []string{"BURROWEE_UPDATE=1"})

	if !strings.Contains(out, "service units not refreshed (needs sudo)") {
		t.Errorf("needs-sudo advisory not printed; output:\n%s", out)
	}

	unitPath := filepath.Join(launchdDir(home), "com.burrowee.gateway.plist")
	if runtime.GOOS != "darwin" {
		unitPath = filepath.Join(systemdDir(home), "burrowee-gateway.service")
	}
	if strings.Contains(out, "service unit: "+unitPath) {
		t.Errorf("false unit success line printed despite failed write; output:\n%s", out)
	}
	if _, err := os.Stat(unitPath); err == nil {
		t.Errorf("unit file written despite failing sudo")
	}

	if got := readInstalled(t, binDir, "burrowee-gateway"); got != "gw-v2-content" {
		t.Errorf("binary swap should still succeed: got %q", got)
	}
}

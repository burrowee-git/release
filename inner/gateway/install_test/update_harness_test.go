// Package install_test harness for BURROWEE_UPDATE mode: the binary sets, the
// seed/stage/read helpers, and the two install.sh runners. Split out of
// update_test.go, which crossed 400 lines — this file is the fixture, that one
// is the assertions. Shared with render_test.go's installShPath/installShEnv/
// stubInitSystem.
package install_test

import (
	"os"
	"os/exec"
	"path/filepath"
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

// allBinsContent returns a map of all 6 bins each mapped to the given body.
func allBinsContent(body string) map[string]string {
	m := make(map[string]string, len(allBins))
	for _, b := range allBins {
		m[b] = body
	}
	return m
}

// serveBins is BINS minus burrowee-gateway-updater — the one binary on its own
// update track — in BINS order. This is the exact set --force must re-place,
// and burrowee-gateway-cli is IN it: the migration calls
// `burrowee-gateway-cli migrate` and the runner probes the INSTALLED cli, so an
// update that swaps everything around the cli guarantees that probe fails.
var serveBins = []string{
	"burrowee",
	"burrowee-gateway",
	"burrowee-gateway-cli",
	"burrowee-gateway-console",
	"burrowee-register",
}

// cliWithMigrate / cliWithoutMigrate stand in for burrowee-gateway-cli. The
// runner's capability probe is `<cli> migrate --help`, so a stand-in has to be
// executable and answer that call — a plain text file would fail the probe for
// the wrong reason and make every migration test pass vacuously.
//
// cliWithoutMigrate is the shipped 0.1.115 cli: every other verb works, the
// verb the migration needs does not exist.
const (
	cliWithMigrate = "#!/bin/sh\n" +
		"case \"$1\" in migrate) exit 0 ;; esac\n" +
		"exit 0\n"
	cliWithoutMigrate = "#!/bin/sh\n" +
		"case \"$1\" in migrate) echo \"unknown verb: migrate\" >&2; exit 2 ;; esac\n" +
		"exit 0\n"
)

// withCLI returns contents with burrowee-gateway-cli replaced by body.
func withCLI(contents map[string]string, body string) map[string]string {
	out := make(map[string]string, len(contents))
	for k, v := range contents {
		out[k] = v
	}
	out["burrowee-gateway-cli"] = body
	return out
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

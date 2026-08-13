// Package install_test is a Go test harness that runs the cli install.sh in a
// sandbox HOME. The cli lays no service unit, so the coverage here is the
// units-only reinstall no-op (BURROWEE_UNITS_ONLY=1 places no binaries and
// exits 0) and the on-disk self-copy a fresh install leaves for LocalReinstall.
package install_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// cliBins is the full cli binary set install.sh expects in the archive.
var cliBins = []string{"burrowee", "burrowee-cli", "burrowee-cli-updater"}

// installShPath resolves inner/cli/install.sh relative to this file.
func installShPath(t *testing.T) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join("..", "install.sh"))
	if err != nil {
		t.Fatalf("resolve install.sh: %v", err)
	}
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("install.sh not found at %s: %v", p, err)
	}
	return p
}

// seedCliBins lays a dummy executable for each cli binary into dir (the install
// cwd; install.sh copies from "./<bin>").
func seedCliBins(t *testing.T, dir string) {
	t.Helper()
	for _, b := range cliBins {
		if err := os.WriteFile(filepath.Join(dir, b), []byte("#!/bin/sh\necho "+b+"\n"), 0o755); err != nil {
			t.Fatalf("seed bin %s: %v", b, err)
		}
	}
}

// runInstall runs install.sh from cwd=staging in a sandbox HOME under the host's
// /bin/sh. Returns combined output. See runInstallUnder (tty_probe_test.go) for
// the shell seam and for why the child is detached from the controlling
// terminal.
func runInstall(t *testing.T, home, staging string, extraEnv ...string) string {
	t.Helper()
	return runInstallUnder(t, "sh", home, staging, extraEnv...)
}

// TestCliUnitsOnlyIsNoop verifies that BURROWEE_UNITS_ONLY=1 is a successful
// no-op: it places no binaries (the cli lays no service unit) and exits 0.
// Binaries are seeded in staging so a regression that copies them is caught.
func TestCliUnitsOnlyIsNoop(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedCliBins(t, staging)

	out := runInstall(t, home, staging, "BURROWEE_UNITS_ONLY=1")

	binDir := filepath.Join(home, ".local", "bin")
	for _, b := range cliBins {
		if _, err := os.Stat(filepath.Join(binDir, b)); err == nil {
			t.Errorf("units-only mode must not place binary %s into %s", b, binDir)
		}
	}
	if !strings.Contains(out, "no service unit") {
		t.Errorf("expected a no-op note mentioning 'no service unit'; got:\n%s", out)
	}
}

// TestCliFreshInstallWritesSelfCopy verifies a fresh install places the binaries
// AND leaves a copy of the installer at $COMP_HOME/install.sh, so LocalReinstall
// has a local installer to invoke offline.
func TestCliFreshInstallWritesSelfCopy(t *testing.T) {
	home := t.TempDir()
	staging := t.TempDir()
	seedCliBins(t, staging)

	runInstall(t, home, staging)

	binDir := filepath.Join(home, ".local", "bin")
	for _, b := range cliBins {
		if _, err := os.Stat(filepath.Join(binDir, b)); err != nil {
			t.Errorf("binary not installed: %s: %v", b, err)
		}
	}

	selfCopy := filepath.Join(home, ".burrowee", "cli", "install.sh")
	if _, err := os.Stat(selfCopy); err != nil {
		t.Errorf("self-copy missing at %s: %v", selfCopy, err)
	}
}

// bin_dir_default_test.go — the DEFAULT $BIN_DIR, pinned statically.
//
// This is deliberately a SOURCE-TEXT assertion, never a dynamic run with
// PREFIX unset: the default is a real, fixed system path (/usr/local/bin)
// since the libexec-to-$BIN_DIR collapse, not a $HOME-relative placeholder —
// exercising it for real on the host running this suite is exactly what the
// suite's hard rule (never touch real /usr/local) forbids. Every dynamic test
// in this package sets BURROWEE_BIN_DIR (installShEnv's default) or, for the
// few that specifically exercise the developer flow, PREFIX — never leaves
// both unset, which is the only way to reach the real default; this file is
// the one place the literal default itself is checked, and it does so by
// reading install.sh's own source rather than running it.
package install_test

import (
	"os"
	"regexp"
	"testing"
)

// wantBinDirDefault is the FULL $BIN_DIR default this repo's install.sh
// resolves to. The gateway repo's sibling pin
// (internal/updatescript/update_sh_default_test.go) checks a related but
// textually different thing — update.sh's PREFIX fallback ("/usr/local", one
// path component short) — because update.sh still computes BIN_DIR as
// "$PREFIX/bin" in two steps where install.sh's BURROWEE_BIN_DIR seam
// collapses that into one. Both describe the same real destination
// (/usr/local/bin); changing either is still a deliberate, cross-repo
// decision — update both pins in the same change, or an update and a fresh
// install can silently resolve to two different directories.
const wantBinDirDefault = "/usr/local/bin"

// binDirDefaultRe matches install.sh's DEFAULT BIN_DIR assignment (the
// PREFIX-unset branch) and captures the ${BURROWEE_BIN_DIR:-<default>}
// fallback — the real default a production host resolves; BURROWEE_BIN_DIR
// itself is a test-only redirect, never set on a real host.
var binDirDefaultRe = regexp.MustCompile(`(?m)^\s*BIN_DIR="\$\{BURROWEE_BIN_DIR:-([^}"]+)\}"`)

// TestInstallShBinDirDefaultMatchesTheExpectedRoot pins install.sh's own
// default. It must FAIL if the default moves without this test being
// updated deliberately — that is the whole point: a silent drift here is a
// host getting binaries in a different directory than every doc, comment and
// the Go side's RootExecDir() describe.
func TestInstallShBinDirDefaultMatchesTheExpectedRoot(t *testing.T) {
	data, err := os.ReadFile(installShPath(t))
	if err != nil {
		t.Fatalf("read install.sh: %v", err)
	}
	m := binDirDefaultRe.FindSubmatch(data)
	if m == nil {
		t.Fatalf(`install.sh: no BIN_DIR="${BURROWEE_BIN_DIR:-.../bin}" default assignment found — ` +
			"the default moved shape and this test can no longer pin it")
	}
	if got := string(m[1]); got != wantBinDirDefault {
		t.Errorf("install.sh's BIN_DIR default = %q, want %q — "+
			"update the gateway repo's update.sh/migrations/*.sh defaults in the same change if this is deliberate",
			got, wantBinDirDefault)
	}
}

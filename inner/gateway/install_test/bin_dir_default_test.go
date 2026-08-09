// bin_dir_default_test.go — the DEFAULT $BIN_DIR, pinned statically.
//
// This is deliberately a SOURCE-TEXT assertion, never a dynamic run with
// PREFIX unset: the default is a real, fixed system path (/usr/local/bin)
// since the libexec-to-$BIN_DIR collapse, not a $HOME-relative placeholder —
// exercising it for real on the host running this suite is exactly what the
// suite's hard rule (never touch real /usr/local) forbids. Every dynamic test
// in this package sets PREFIX explicitly for that reason; this file is the
// one place the literal default itself is checked, and it does so by reading
// install.sh's own source rather than running it.
package install_test

import (
	"os"
	"regexp"
	"testing"
)

// wantBinDirDefault is the fallback this repo and the gateway repo's
// update.sh / migrations/run.sh / migrations/v1_to_v2.sh must all agree on.
// Changing it here is a deliberate, cross-repo decision — see this file's
// header and the sibling pin in the gateway repo's
// internal/updatescript/update_sh_default_test.go, which must be updated in
// the same change or the two scripts silently diverge on where an update
// places binaries versus where a fresh install did.
const wantBinDirDefault = "/usr/local"

// binDirDefaultRe matches install.sh's BIN_DIR assignment and captures the
// ${PREFIX:-<default>} fallback.
var binDirDefaultRe = regexp.MustCompile(`(?m)^BIN_DIR="\$\{PREFIX:-([^}"]+)\}/bin"`)

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
		t.Fatalf(`install.sh: no BIN_DIR="${PREFIX:-...}/bin" assignment found — ` +
			"the default moved shape and this test can no longer pin it")
	}
	if got := string(m[1]); got != wantBinDirDefault {
		t.Errorf("install.sh's BIN_DIR default = %q, want %q — "+
			"update the gateway repo's update.sh/migrations/*.sh defaults in the same change if this is deliberate",
			got, wantBinDirDefault)
	}
}

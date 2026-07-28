package relconfig

import (
	"strings"
	"testing"
)

// The updater binary must carry the core/updater pin, and every OTHER binary
// must keep the component stamp. Shipping the stamp on the updater is what made
// a node's reported updater version permanently unequal to the catalog's.
func TestBinsStampsUpdaterWithPinNotStamp(t *testing.T) {
	const stamp, pin = "v0.1.99.2026.07.28.d4dc509d", "v0.1.12"
	got, err := Bins("edge", stamp, "abc123", "", pin)
	if err != nil {
		t.Fatalf("Bins: %v", err)
	}
	var sawUpdater bool
	for _, b := range got {
		want := "-X main.version=" + stamp
		if strings.HasSuffix(b.Name, "-updater") {
			sawUpdater = true
			want = "-X main.version=" + pin
		}
		if !strings.Contains(b.Ldflags, want) {
			t.Errorf("%s: ldflags %q missing %q", b.Name, b.Ldflags, want)
		}
	}
	if !sawUpdater {
		t.Fatal("edge produced no *-updater binary — test asserts nothing")
	}
}

// edge bakes consolePubHexProd alongside the version; pinning must REPLACE the
// version term, never rebuild the flag string, or that identity is silently lost.
func TestUpdaterPinPreservesComponentLdflags(t *testing.T) {
	got, err := Bins("edge", "vSTAMP", "abc123", "", "v0.1.12")
	if err != nil {
		t.Fatalf("Bins: %v", err)
	}
	for _, b := range got {
		if strings.HasSuffix(b.Name, "-updater") {
			if !strings.Contains(b.Ldflags, "abc123") {
				t.Fatalf("%s: consolePubHex dropped by pinning: %q", b.Name, b.Ldflags)
			}
		}
	}
}

// An empty pin (agent, which has no core/updater dependency) leaves every
// binary on the component stamp — matching build.sh, which excludes agent.
func TestEmptyPinLeavesStamp(t *testing.T) {
	got, err := Bins("cli", "vSTAMP", "", "", "")
	if err != nil {
		t.Fatalf("Bins: %v", err)
	}
	for _, b := range got {
		if !strings.Contains(b.Ldflags, "-X main.version=vSTAMP") {
			t.Errorf("%s: ldflags %q lost the stamp", b.Name, b.Ldflags)
		}
	}
}

package relconfig

import (
	"path/filepath"
	"testing"
)

// Relay's updater lives in the nested cli module; every other component's is at
// the repo root. Resolving relay at the root returns no pin, which silently kept
// the component stamp on burrowee-relay-updater in v0.1.37.
func TestUpdaterModuleDirNestsForRelayOnly(t *testing.T) {
	const src = "/src/relay"
	if got, want := UpdaterModuleDir("relay", src), filepath.Join(src, "cli"); got != want {
		t.Errorf("relay: got %q, want %q", got, want)
	}
	for _, comp := range []string{"cli", "gateway", "edge", "agent"} {
		if got := UpdaterModuleDir(comp, src); got != src {
			t.Errorf("%s: got %q, want %q", comp, got, src)
		}
	}
}

// Only agent and the dispatcher legitimately have no core/updater dependency.
func TestRequiresUpdaterPin(t *testing.T) {
	for _, comp := range []string{"cli", "gateway", "edge", "relay"} {
		if !RequiresUpdaterPin(comp) {
			t.Errorf("%s must require a pin", comp)
		}
	}
	for _, comp := range []string{"agent", "burrowee"} {
		if RequiresUpdaterPin(comp) {
			t.Errorf("%s must not require a pin", comp)
		}
	}
}

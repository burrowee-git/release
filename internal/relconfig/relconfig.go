package relconfig

import (
	"fmt"

	"github.com/burrowee-git/release-kit/build"
)

// Component describes one burrowee component's build config.
type Component struct {
	Name      string
	SrcDirEnv string
	Bins      []build.BinSpec
}

var Components = []string{"cli", "gateway", "edge", "agent", "relay", "burrowee"}

func Targets() []build.Target {
	return []build.Target{
		{OS: "darwin", Arch: "arm64"}, {OS: "darwin", Arch: "amd64"},
		{OS: "linux", Arch: "arm64"}, {OS: "linux", Arch: "amd64"},
	}
}

// Bins returns the exact build.BinSpec list for comp, mirroring tools/build.sh.
// consolePubHex is required for edge+relay; consoleURL defaults are applied by
// the caller (orchestrate) — pass "" only for components that don't need them.
func Bins(comp, stamp, consolePubHex, consoleURL string) ([]build.BinSpec, error) {
	v := "-X main.version=" + stamp
	switch comp {
	case "cli":
		return []build.BinSpec{
			{Name: "burrowee-cli", Package: "./cmd/burrowee-cli", Ldflags: v},
			{Name: "burrowee-cli-updater", Package: "./cmd/burrowee-cli-updater", Ldflags: v},
		}, nil
	case "gateway":
		return []build.BinSpec{
			{Name: "burrowee-gateway", Package: "./cmd/burrowee-gateway", Ldflags: v},
			{Name: "burrowee-gateway-cli", Package: "./cmd/burrowee-gateway-cli", Ldflags: v},
			{Name: "burrowee-gateway-console", Package: "./cmd/burrowee-gateway-console", Ldflags: v},
			{Name: "burrowee-register", Package: "./cmd/burrowee-register", Ldflags: v},
			{Name: "burrowee-gateway-updater", Package: "./cmd/burrowee-gateway-updater", Ldflags: v},
		}, nil
	case "agent":
		av := v + " -X github.com/burrowee-git/agent/internal/agent/command.version=" + stamp
		return []build.BinSpec{
			{Name: "burrowee-agent", Package: "./cmd/burrowee-agent", Ldflags: av},
		}, nil
	case "edge":
		if consolePubHex == "" {
			return nil, fmt.Errorf("edge requires consolePubHex")
		}
		ev := v + " -X main.consolePubHexProd=" + consolePubHex
		return []build.BinSpec{
			{Name: "burrowee-edge", Package: "./cmd/burrowee-edge", Ldflags: ev},
			{Name: "burrowee-edge-cli", Package: "./cmd/burrowee-edge-cli", Ldflags: ev},
			{Name: "burrowee-edge-updater", Package: "./cmd/burrowee-edge-updater", Ldflags: ev},
		}, nil
	case "relay":
		if consolePubHex == "" {
			return nil, fmt.Errorf("relay requires consolePubHex")
		}
		if consoleURL == "" {
			consoleURL = "wss://relay-api.burrowee.com"
		}
		ident := v + " -X main.consoleURLProd=" + consoleURL + " -X main.consolePubHexProd=" + consolePubHex
		return []build.BinSpec{
			{Name: "burrowee-relay", Package: "./cmd/burrowee-relay", Ldflags: v},
			// nested cli module: build.sh does cd cli && GOWORK=off, pkg ./cli→.
			{Name: "burrowee-relay-cli", Package: ".", SubDir: "cli", GoWork: "off", Ldflags: ident},
			// ./cli/cmd/burrowee-relay-updater → ./cmd/burrowee-relay-updater under SubDir cli
			{Name: "burrowee-relay-updater", Package: "./cmd/burrowee-relay-updater", SubDir: "cli", GoWork: "off", Ldflags: ident},
		}, nil
	case "burrowee":
		return []build.BinSpec{
			{Name: "burrowee", Package: ".", Ldflags: v},
		}, nil
	}
	return nil, fmt.Errorf("unknown component %q", comp)
}

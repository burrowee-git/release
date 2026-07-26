package main

// Console signing-pubkey resolution for edge/relay builds. Split out of
// build.go, which crossed 400 lines.

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// placeholderConsolePubHex is the dead-key placeholder shipped in
// config/console-pub.hex templates: valid-length hex a runtime check can't
// distinguish from a real key. Mirrors tools/build.sh's edge/relay guard.
const placeholderConsolePubHex = "0000000000000000000000000000000000000000000000000000000000000000"

// resolveConsolePubHex returns the console signing pubkey hex for edge/relay
// builds. An explicit Options.ConsolePubHex wins; otherwise it reads
// config/console-pub.hex under RepoDir (skipping comment/blank lines, same
// parsing as tools/release.sh's console_pub_hex()). A missing config file
// resolves to "" with no error — components that don't need a console key
// (cli/gateway/agent/burrowee) never hit this file. Either way, the resolved
// value is rejected if it's the 64-zero placeholder.
func resolveConsolePubHex(o Options) (string, error) {
	hex := o.ConsolePubHex
	if hex == "" {
		path := filepath.Join(o.RepoDir, "config", "console-pub.hex")
		raw, err := os.ReadFile(path)
		if err != nil {
			if os.IsNotExist(err) {
				return "", nil
			}
			return "", fmt.Errorf("read %s: %w", path, err)
		}
		for _, line := range strings.Split(string(raw), "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			hex = line
			break
		}
	}
	if hex == placeholderConsolePubHex {
		return "", fmt.Errorf("console pubkey is the placeholder — set config/console-pub.hex to the real console signing key before an edge/relay release")
	}
	return hex, nil
}

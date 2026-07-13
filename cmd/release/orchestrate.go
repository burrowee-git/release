package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/burrowee-git/release-kit/build"
	"github.com/burrowee-git/release-kit/checksum"
	"github.com/burrowee-git/release-kit/minisign"
	"github.com/burrowee-git/release-kit/sign"
	"github.com/burrowee-git/release-kit/vulncheck"

	"github.com/burrowee-git/release/internal/relconfig"
)

type Options struct {
	Component, OutDir, RepoDir, DispatcherDir string
	ConsolePubHex, ConsoleURL, MinisignKey    string
}

type Result struct {
	Stamp         string
	Zips          []string
	Sums, Minisig string
}

func runOrchestrate(args []string) error {
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	var o Options
	fs.StringVar(&o.Component, "component", "", "cli|gateway|edge|agent|relay|burrowee")
	fs.StringVar(&o.OutDir, "out", "", "scratch output dir")
	fs.StringVar(&o.RepoDir, "repo", ".", "release repo worktree")
	fs.StringVar(&o.DispatcherDir, "dispatcher", "", "dispatcher source worktree (defaults to repo)")
	fs.StringVar(&o.MinisignKey, "key", "", "minisign secret key (defaults to TEST key)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	// defaults resolved in orchestrate(): console keys from config/console-pub.hex, key from tools/testkeys.
	_, err := orchestrate(context.Background(), o)
	return err
}

func orchestrate(ctx context.Context, o Options) (*Result, error) {
	if o.DispatcherDir == "" {
		o.DispatcherDir = o.RepoDir
	}
	// 1. CVE gate (fail-closed) — scan the component module.
	if err := vulncheck.Gate(ctx, []vulncheck.Module{{Name: o.Component, Dir: o.RepoDir}},
		vulncheck.GateOpts{ReportDir: filepath.Join(o.OutDir, "vulncheck")}); err != nil {
		return nil, fmt.Errorf("cve gate: %w", err)
	}
	// 2. Stamp (read-only, no bump).
	stamp, err := relconfig.Stamp(ctx, filepath.Join(o.RepoDir, "versions", o.Component), o.RepoDir)
	if err != nil {
		return nil, err
	}
	// 3. Build component matrix.
	consolePubHex, err := resolveConsolePubHex(o)
	if err != nil {
		return nil, err
	}
	bins, err := relconfig.Bins(o.Component, stamp, consolePubHex, o.ConsoleURL)
	if err != nil {
		return nil, err
	}
	arts, err := build.Compile(ctx, build.Spec{
		SrcDir: o.RepoDir, OutDir: filepath.Join(o.OutDir, stamp),
		Targets: relconfig.Targets(), Bins: bins, Signer: sign.AdHocSigner{},
	})
	if err != nil {
		return nil, fmt.Errorf("compile %s: %w", o.Component, err)
	}
	res := &Result{Stamp: stamp}
	// 4. Assemble per-target zips (Task 4) → res.Zips, then:
	//    checksum.WriteSums(res.Zips, sums) + minisign.Sign(ctx, sums, key).
	//    Until Task 4, sum over the raw artifacts so the flow is exercised end-to-end.
	//    build.Paths(arts) alone can't feed checksum.WriteSums directly: every
	//    target shares the same bin basenames (e.g. "burrowee-cli" appears once
	//    per OS/Arch), and WriteSums rejects duplicate basenames as an ambiguous
	//    SHA256SUMS. Per-target zip names are unique, so that collision goes away
	//    after Task 4; until then, checksum only the host-target artifacts (the
	//    one target directory whose bin names are guaranteed distinct from each
	//    other) as the interim smoke check that checksum+minisign run correctly.
	// TODO(task4): replace this host-target subset with res.Zips once assembly lands.
	sums := filepath.Join(o.OutDir, stamp, "SHA256SUMS.txt")
	if err := checksum.WriteSums(build.Paths(hostTargetArtifacts(arts)), sums); err != nil {
		return nil, fmt.Errorf("checksum: %w", err)
	}
	key := o.MinisignKey
	if key == "" {
		key = filepath.Join(o.RepoDir, "tools", "testkeys", "burrowee-release-test.key")
	}
	if _, statErr := os.Stat(key); statErr == nil {
		if err := minisign.Sign(ctx, sums, key); err != nil {
			return nil, fmt.Errorf("minisign: %w", err)
		}
		res.Minisig = sums + ".minisig"
	}
	res.Sums = sums
	return res, nil
}

// hostTargetArtifacts filters arts down to the build host's own OS/Arch, whose
// bin basenames are guaranteed distinct from each other (unlike the full
// cross-target set, where every target ships a same-named binary). Falls back
// to the full set if the host target wasn't built (shouldn't happen given
// relconfig.Targets(), but fail open rather than produce an empty manifest).
func hostTargetArtifacts(arts []build.Artifact) []build.Artifact {
	var host []build.Artifact
	for _, a := range arts {
		if a.OS == runtime.GOOS && a.Arch == runtime.GOARCH {
			host = append(host, a)
		}
	}
	if len(host) == 0 {
		return arts
	}
	return host
}

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

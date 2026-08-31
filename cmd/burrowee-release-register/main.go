// burrowee-release-register manages the Ed25519 release signing identity,
// performs the nonce→sign→POST handshake against the Burrowee console, and
// publishes binaries to R2.
//
// Usage:
//
//	burrowee-release-register keygen [--dir <d>]
//	burrowee-release-register register --dir <d> --payload-file <f> [--dry-run]
//	burrowee-release-register publish --comp <cli|gateway|edge|agent|all> [--dir <d>] [--version <v>]
//	burrowee-release-register publish-dir --comp <cli|gateway|edge|agent|relay> [--channel stable|beta] --stamp <stamp> --from-dir <dir> [--dir <d>]
//	burrowee-release-register publish-relay [--channel stable|beta] --stamp <stamp> --from-dir <dir> [--dir <d>]
//	burrowee-release-register fetch-dir --comp <cli|gateway|edge|agent|relay> --stamp <stamp> --to-dir <dir> [--dir <d>]
//	burrowee-release-register prune --comp <cli|gateway|edge|agent|relay|all> [--channel stable|beta] [--dir <d>] [--execute]
//	burrowee-release-register key-prefix --comp <cli|gateway|edge|agent|relay> [--channel stable|beta]
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"path"
	"path/filepath"

	"github.com/burrowee-git/release/internal/r2"
	"github.com/burrowee-git/release/internal/register"
)

func main() {
	log.SetFlags(0)
	log.SetPrefix("burrowee-release-register: ")

	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}

	switch os.Args[1] {
	case "keygen":
		runKeygen(os.Args[2:])
	case "register":
		runRegister(os.Args[2:])
	case "publish":
		runPublish(os.Args[2:])
	case "publish-dir":
		runPublishDir(os.Args[2:])
	case "publish-relay":
		runPublishRelay(os.Args[2:])
	case "fetch-dir":
		runFetchDir(os.Args[2:])
	case "prune":
		runPrune(os.Args[2:])
	case "key-prefix":
		runKeyPrefix(os.Args[2:])
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n\n", os.Args[1])
		usage()
		os.Exit(1)
	}
}

func defaultDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ".burrowee/release"
	}
	return filepath.Join(home, ".burrowee", "release")
}

func usage() {
	fmt.Fprintln(os.Stderr, `usage:
  burrowee-release-register keygen [--dir <d>]
  burrowee-release-register register --dir <d> --payload-file <f> [--dry-run]
  burrowee-release-register publish --comp <cli|gateway|edge|agent|all> [--dir <d>] [--version <v>]
  burrowee-release-register publish-dir --comp <cli|gateway|edge|agent|relay> --stamp <stamp> --from-dir <dir> [--dir <d>]
  burrowee-release-register publish-relay [--channel stable|beta] --stamp <stamp> --from-dir <dir> [--dir <d>]
  burrowee-release-register fetch-dir --comp <cli|gateway|edge|agent|relay> --stamp <stamp> --to-dir <dir> [--dir <d>]
  burrowee-release-register prune --comp <cli|gateway|edge|agent|relay|all> [--channel stable|beta] [--dir <d>] [--execute]
  burrowee-release-register key-prefix --comp <cli|gateway|edge|agent|relay> [--channel stable|beta]`)
}

func runKeygen(args []string) {
	fs := flag.NewFlagSet("keygen", flag.ExitOnError)
	dir := fs.String("dir", defaultDir(), "directory for key files")
	fs.Parse(args) //nolint:errcheck

	pubB64, err := register.Keygen(*dir)
	if err != nil {
		log.Fatalf("keygen: %v", err)
	}
	fmt.Println(pubB64)
}

func runRegister(args []string) {
	fs := flag.NewFlagSet("register", flag.ExitOnError)
	dir := fs.String("dir", defaultDir(), "directory holding config.toml and client.key")
	payloadFile := fs.String("payload-file", "", "path to JSON payload file (required)")
	dryRun := fs.Bool("dry-run", false, "print details without making network calls")
	fs.Parse(args) //nolint:errcheck

	if *payloadFile == "" {
		fmt.Fprintln(os.Stderr, "register: --payload-file is required")
		fs.Usage()
		os.Exit(1)
	}

	cfg, err := register.LoadConfig(*dir)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	payload, err := os.ReadFile(*payloadFile)
	if err != nil {
		log.Fatalf("read payload file: %v", err)
	}

	if err := register.Register(cfg, payload, *dryRun); err != nil {
		// Non-fatal: log and exit non-zero so release.sh can note it.
		log.Printf("register: %v (register manually later)", err)
		os.Exit(1)
	}
}

func runPublish(args []string) {
	fs := flag.NewFlagSet("publish", flag.ExitOnError)
	dir := fs.String("dir", defaultDir(), "directory holding config.toml and r2.key")
	comp := fs.String("comp", "", "component: cli|gateway|edge|agent|all (required)")
	version := fs.String("version", "", "specific public version (default: current)")
	fs.Parse(args) //nolint:errcheck

	if *comp == "" {
		fmt.Fprintln(os.Stderr, "publish: --comp is required (cli|gateway|edge|agent|all)")
		fs.Usage()
		os.Exit(1)
	}
	consoleURL, r2cfg, err := register.LoadPublishConfig(*dir)
	if err != nil {
		log.Fatalf("publish: %v", err)
	}
	client := r2.New(r2cfg.AccountID, r2cfg.Bucket, r2cfg.AccessKeyID, r2cfg.Secret, nil)
	deps := register.PublishDeps{ConsoleURL: consoleURL, HTTP: http.DefaultClient, R2: client, Out: os.Stdout}

	comps := []string{*comp}
	if *comp == "all" {
		comps = []string{"cli", "gateway", "edge", "agent"}
	}
	for _, c := range comps {
		if err := register.Publish(context.Background(), deps, c, *version); err != nil {
			log.Fatalf("publish %s: %v", c, err)
		}
	}
}

// runPublishDir uploads a component's artifacts from a local directory to R2
// under <comp>/<stamp>/. It reads R2 credentials from <dir>/config.toml +
// r2.key (the same location the register tool uses for public components). No
// catalog row is required — the files are read directly from --from-dir and
// verified against SHA256SUMS.txt before upload.
//
// This is the general form of the direct-to-R2 upload: relay was the first
// (and, before beta, only) private component, so publish-relay predates this
// and stays as a thin wrapper below with its own flag names. A beta cut of
// any component is private the same way until promoted (spec §5.3), so
// cli/gateway/edge/agent go through this verb too.
func runPublishDir(args []string) {
	fs := flag.NewFlagSet("publish-dir", flag.ExitOnError)
	dir := fs.String("dir", defaultDir(), "directory holding config.toml and r2.key")
	comp := fs.String("comp", "", "component: cli|gateway|edge|agent|relay (required)")
	channel := fs.String("channel", "stable", "channel: stable|beta (default stable)")
	stamp := fs.String("stamp", "", "release stamp (e.g. v0.1.3.2026.06.21.abc12345) — becomes the R2 prefix <comp>/[beta/]<stamp>/")
	fromDir := fs.String("from-dir", "", "local directory containing the component artifacts (required)")
	fs.Parse(args) //nolint:errcheck

	if *comp == "" || *stamp == "" || *fromDir == "" {
		fmt.Fprintln(os.Stderr, "publish-dir: --comp, --stamp and --from-dir are required")
		fs.Usage()
		os.Exit(1)
	}
	switch *channel {
	case "stable", "beta":
	default:
		fmt.Fprintf(os.Stderr, "publish-dir: --channel must be stable or beta (got %q)\n", *channel)
		os.Exit(2)
	}

	_, r2cfg, err := register.LoadPublishConfig(*dir)
	if err != nil {
		log.Fatalf("publish-dir: %v", err)
	}
	client := r2.New(r2cfg.AccountID, r2cfg.Bucket, r2cfg.AccessKeyID, r2cfg.Secret, nil)

	if err := register.PublishFromDir(context.Background(), client, *comp, *channel, *fromDir, *stamp, os.Stdout); err != nil {
		log.Fatalf("publish-dir: %v", err)
	}
}

// runPublishRelay uploads relay artifacts from a local directory to R2 under
// relay/[beta/]<stamp>/ — the old relay-only verb, kept with its original flag
// names (no --comp) and now a thin wrapper over runPublishDir's underlying call
// with comp = "relay".
//
// This is called by do_release_relay in release.sh after the signing step, in
// place of the former scp block.
//
// --channel is NOT cosmetic here. do_release_relay supports `--channel beta`
// end to end, so a relay beta cut reaches this verb; hardcoding "stable" made
// it overwrite relay/latest.json (the STABLE pointer) with a beta stamp and
// land the artifacts at relay/<stamp>/, where the stable prune skips them
// (chOf reads "beta" out of the stamp) and the beta prune never lists them
// (it lists relay/beta/) — permanently unprunable. The default stays "stable"
// so distribute_relay and any hand invocation behave exactly as before.
func runPublishRelay(args []string) {
	fs := flag.NewFlagSet("publish-relay", flag.ExitOnError)
	dir := fs.String("dir", defaultDir(), "directory holding config.toml and r2.key")
	channel := fs.String("channel", "stable", "channel: stable|beta (default stable)")
	stamp := fs.String("stamp", "", "release stamp (e.g. v0.1.3.2026.06.21.abc12345) — becomes the R2 prefix relay/[beta/]<stamp>/")
	fromDir := fs.String("from-dir", "", "local directory containing the relay artifacts (required)")
	fs.Parse(args) //nolint:errcheck

	if *stamp == "" || *fromDir == "" {
		fmt.Fprintln(os.Stderr, "publish-relay: --stamp and --from-dir are required")
		fs.Usage()
		os.Exit(1)
	}
	switch *channel {
	case "stable", "beta":
	default:
		fmt.Fprintf(os.Stderr, "publish-relay: --channel must be stable or beta (got %q)\n", *channel)
		os.Exit(2)
	}

	_, r2cfg, err := register.LoadPublishConfig(*dir)
	if err != nil {
		log.Fatalf("publish-relay: %v", err)
	}
	client := r2.New(r2cfg.AccountID, r2cfg.Bucket, r2cfg.AccessKeyID, r2cfg.Secret, nil)

	if err := register.PublishFromDir(context.Background(), client, "relay", *channel, *fromDir, *stamp, os.Stdout); err != nil {
		log.Fatalf("publish-relay: %v", err)
	}
}

// runFetchDir lists <comp>/<stamp>/ in R2 — the pre-migration flat layout,
// not register.KeyPrefix's <comp>/beta/<stamp>/ — Gets each object, and
// writes it into --to-dir under its base name. It is the inverse of
// publish-dir/PublishFromDir, built for the one-time beta-layout migration
// (tools/migrate-beta-layout.sh): the only way to re-publish an artifact
// under a different key without rebuilding it from source is to read the
// bytes back out first.
func runFetchDir(args []string) {
	fs := flag.NewFlagSet("fetch-dir", flag.ExitOnError)
	dir := fs.String("dir", defaultDir(), "directory holding config.toml and r2.key")
	comp := fs.String("comp", "", "component: cli|gateway|edge|agent|relay (required)")
	stamp := fs.String("stamp", "", "release stamp (e.g. v0.2.21.beta.2026.08.28.716c7ede) — read from R2 prefix <comp>/<stamp>/ (required)")
	toDir := fs.String("to-dir", "", "local directory to write the fetched objects into (required)")
	fs.Parse(args) //nolint:errcheck

	if *comp == "" || *stamp == "" || *toDir == "" {
		fmt.Fprintln(os.Stderr, "fetch-dir: --comp, --stamp and --to-dir are required")
		fs.Usage()
		os.Exit(1)
	}

	_, r2cfg, err := register.LoadPublishConfig(*dir)
	if err != nil {
		log.Fatalf("fetch-dir: %v", err)
	}
	client := r2.New(r2cfg.AccountID, r2cfg.Bucket, r2cfg.AccessKeyID, r2cfg.Secret, nil)

	if err := os.MkdirAll(*toDir, 0o755); err != nil {
		log.Fatalf("fetch-dir: mkdir %s: %v", *toDir, err)
	}

	ctx := context.Background()
	prefix := *comp + "/" + *stamp + "/"
	keys, err := client.List(ctx, prefix)
	if err != nil {
		log.Fatalf("fetch-dir: list %s: %v", prefix, err)
	}
	if len(keys) == 0 {
		log.Fatalf("fetch-dir: no objects found under %s", prefix)
	}
	for _, key := range keys {
		body, err := client.Get(ctx, key)
		if err != nil {
			log.Fatalf("fetch-dir: %v", err)
		}
		dest := filepath.Join(*toDir, path.Base(key))
		if err := os.WriteFile(dest, body, 0o644); err != nil {
			log.Fatalf("fetch-dir: write %s: %v", dest, err)
		}
		fmt.Printf("✓ %s -> %s\n", key, dest)
	}
}

// runPrune drops all but the newest N version prefixes for a component in R2,
// on the given channel ONLY (a stable prune never counts or deletes a beta
// version, and vice versa — spec §5.5): stable keeps 3 for relay and 10 for
// every other component; beta keeps only the latest — 1 — regardless of
// component, since the beta track is disposable. Dry-run by default;
// --execute performs the deletions. R2 credentials come from
// <dir>/config.toml + r2.key.
func runPrune(args []string) {
	fs := flag.NewFlagSet("prune", flag.ExitOnError)
	dir := fs.String("dir", defaultDir(), "directory holding config.toml and r2.key")
	comp := fs.String("comp", "", "component: cli|gateway|edge|agent|relay|all (required)")
	channel := fs.String("channel", "stable", "channel: stable|beta (default stable)")
	execute := fs.Bool("execute", false, "actually delete (default: dry-run)")
	fs.Parse(args) //nolint:errcheck

	if *comp == "" {
		fmt.Fprintln(os.Stderr, "prune: --comp is required (cli|gateway|edge|agent|relay|all)")
		fs.Usage()
		os.Exit(1)
	}
	switch *channel {
	case "stable", "beta":
	default:
		fmt.Fprintf(os.Stderr, "prune: --channel must be stable or beta (got %q)\n", *channel)
		os.Exit(2)
	}
	_, r2cfg, err := register.LoadPublishConfig(*dir)
	if err != nil {
		log.Fatalf("prune: %v", err)
	}
	client := r2.New(r2cfg.AccountID, r2cfg.Bucket, r2cfg.AccessKeyID, r2cfg.Secret, nil)

	comps := []string{*comp}
	if *comp == "all" {
		comps = []string{"cli", "gateway", "edge", "agent", "relay"}
	}
	for _, c := range comps {
		if _, err := register.Prune(context.Background(), client, c, *channel, *execute, os.Stdout); err != nil {
			log.Fatalf("prune %s: %v", c, err)
		}
	}
}

// runKeyPrefix prints the R2 key prefix for comp on channel. It exists so
// tools/release.sh can ask for the layout instead of rebuilding it in shell —
// see register.KeyPrefix.
func runKeyPrefix(args []string) {
	fs := flag.NewFlagSet("key-prefix", flag.ExitOnError)
	comp := fs.String("comp", "", "component: cli|gateway|edge|agent|relay (required)")
	channel := fs.String("channel", "stable", "channel: stable|beta (default stable)")
	fs.Parse(args) //nolint:errcheck

	if *comp == "" {
		fmt.Fprintln(os.Stderr, "key-prefix: --comp is required")
		fs.Usage()
		os.Exit(1)
	}
	switch *channel {
	case "stable", "beta":
	default:
		fmt.Fprintf(os.Stderr, "key-prefix: --channel must be stable or beta (got %q)\n", *channel)
		os.Exit(2)
	}
	fmt.Println(register.KeyPrefix(*comp, *channel))
}

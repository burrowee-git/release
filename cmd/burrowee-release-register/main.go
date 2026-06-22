// burrowee-release-register manages the Ed25519 release signing identity,
// performs the nonce→sign→POST handshake against the Burrowee console, and
// publishes binaries to R2.
//
// Usage:
//
//	burrowee-release-register keygen [--dir <d>]
//	burrowee-release-register register --dir <d> --payload-file <f> [--dry-run]
//	burrowee-release-register publish --comp <cli|gateway|edge|all> [--dir <d>] [--version <v>]
//	burrowee-release-register publish-relay --stamp <stamp> --from-dir <dir> [--dir <d>]
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
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
	case "publish-relay":
		runPublishRelay(os.Args[2:])
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
  burrowee-release-register publish --comp <cli|gateway|edge|all> [--dir <d>] [--version <v>]
  burrowee-release-register publish-relay --stamp <stamp> --from-dir <dir> [--dir <d>]`)
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
	comp := fs.String("comp", "", "component: cli|gateway|edge|all (required)")
	version := fs.String("version", "", "specific public version (default: current)")
	fs.Parse(args) //nolint:errcheck

	if *comp == "" {
		fmt.Fprintln(os.Stderr, "publish: --comp is required (cli|gateway|edge|all)")
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
		comps = []string{"cli", "gateway", "edge"}
	}
	for _, c := range comps {
		if err := register.Publish(context.Background(), deps, c, *version); err != nil {
			log.Fatalf("publish %s: %v", c, err)
		}
	}
}

// runPublishRelay uploads relay artifacts from a local directory to R2 under
// relay/<stamp>/. It reads R2 credentials from <dir>/config.toml + r2.key (the
// same location the register tool uses for public components). No catalog row is
// required — the files are read directly from --from-dir and verified against
// SHA256SUMS.txt before upload.
//
// This is called by do_release_relay in release.sh after the signing step, in
// place of the former scp block.
func runPublishRelay(args []string) {
	fs := flag.NewFlagSet("publish-relay", flag.ExitOnError)
	dir := fs.String("dir", defaultDir(), "directory holding config.toml and r2.key")
	stamp := fs.String("stamp", "", "release stamp (e.g. v0.1.3.2026.06.21.abc12345) — becomes the R2 prefix relay/<stamp>/")
	fromDir := fs.String("from-dir", "", "local directory containing the relay artifacts (required)")
	fs.Parse(args) //nolint:errcheck

	if *stamp == "" || *fromDir == "" {
		fmt.Fprintln(os.Stderr, "publish-relay: --stamp and --from-dir are required")
		fs.Usage()
		os.Exit(1)
	}

	_, r2cfg, err := register.LoadPublishConfig(*dir)
	if err != nil {
		log.Fatalf("publish-relay: %v", err)
	}
	client := r2.New(r2cfg.AccountID, r2cfg.Bucket, r2cfg.AccessKeyID, r2cfg.Secret, nil)

	if err := register.PublishFromDir(context.Background(), client, *fromDir, *stamp, os.Stdout); err != nil {
		log.Fatalf("publish-relay: %v", err)
	}
}

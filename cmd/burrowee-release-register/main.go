// burrowee-release-register manages the Ed25519 release signing identity
// and performs the nonce→sign→POST handshake against the Burrowee console.
//
// Usage:
//
//	burrowee-release-register keygen [--dir <d>]
//	burrowee-release-register register --dir <d> --payload-file <f> [--dry-run]
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"

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
  burrowee-release-register register --dir <d> --payload-file <f> [--dry-run]`)
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

// Command release orchestrates a burrowee release cut using release-kit
// primitives, and (subcommand `harness`) validates its output against the
// live release.sh pipeline. Produce-to-scratch only; distribution stays in
// release.sh.
package main

import (
	"fmt"
	"os"
)

func usage() string {
	return "usage: release <run|harness> --component <cli|gateway|edge|agent|relay|burrowee> --out <dir>"
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, usage())
		os.Exit(2)
	}
	switch os.Args[1] {
	case "run":
		if err := runOrchestrate(os.Args[2:]); err != nil {
			fmt.Fprintln(os.Stderr, "✗", err)
			os.Exit(1)
		}
	case "harness":
		if err := runHarness(os.Args[2:]); err != nil {
			fmt.Fprintln(os.Stderr, "✗", err)
			os.Exit(1)
		}
	default:
		fmt.Fprintln(os.Stderr, usage())
		os.Exit(2)
	}
}

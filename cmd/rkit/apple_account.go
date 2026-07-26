package main

// Apple account plugin resolution for `rkit build --apple/--public`. Split out
// of build.go, which crossed 400 lines; its tests are apple_account_test.go.

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// appleAccountFiles are the config file names, in precedence order, that name
// the Apple account plugin folder (one line: the folder name).
var appleAccountFiles = []string{"config/apple-account", "config/apple.account"}

// loadAppleAccount sets APPLE_ACCOUNT / APPLE_ACCOUNT_DIR / APPLE_HOME from
// config/apple-account so modernech-sign picks the project account plugin. It is
// called only when --apple/--public is set, so every failure is fatal: entering
// the Developer-ID path with no account resolved produces an AD-HOC signed
// build while the operator believes it is Developer-ID signed and notarized.
// It used to return silently on every failure mode and runBuild ignored that it
// had done nothing.
//
// APPLE_HOME (the directory holding one folder per account) must come from the
// environment — no operator's machine layout is baked into this public repo, and
// a $HOME-derived default silently becomes a RELATIVE path when HOME is unset
// (launchd, cron, a detached harness session).
//
// NOTE FOR OPERATORS: `rkit build` is the PRIMARY produce path — tools/release.sh
// never invokes it, it distributes what rkit already staged — so this requirement
// lands on the normal cutting flow, not on a side path. Export APPLE_HOME (or
// APPLE_ACCOUNT_DIR) before `rkit build --public`. tools/RUNBOOK.md → "Cutting a
// public release: the Apple environment" documents it, and every failure below
// names the two variables.
func loadAppleAccount(repoDir string) error {
	if dir := os.Getenv("APPLE_ACCOUNT_DIR"); dir != "" {
		fmt.Fprintf(os.Stderr, "→ Apple account dir (from APPLE_ACCOUNT_DIR): %s\n", dir)
		return nil
	}
	// An operator cutting under a second account exports APPLE_ACCOUNT; honour
	// it rather than overriding it from the repo's config file. tools/apple_sign.sh
	// (release.sh's copy of this resolution) now uses the same precedence — the two
	// resolve independently, since neither entry point invokes the other, so the
	// contract they share is the precedence, not an inherited environment.
	account := os.Getenv("APPLE_ACCOUNT")
	if account == "" {
		var err error
		if account, err = readAppleAccountFile(repoDir); err != nil {
			return err
		}
	}
	home := os.Getenv("APPLE_HOME")
	if home == "" {
		return fmt.Errorf("apple signing requested but APPLE_HOME is not set: "+
			"export it as the ABSOLUTE directory holding one folder per Apple account "+
			"(it is then joined with %q), or set APPLE_ACCOUNT_DIR to that account's folder "+
			"directly. `rkit build --public` is the primary produce path and does not inherit "+
			"anything from tools/release.sh; see tools/RUNBOOK.md → \"Cutting a public release: "+
			"the Apple environment\"", account)
	}
	if !filepath.IsAbs(home) {
		return fmt.Errorf("apple signing requested but APPLE_HOME=%q is not an absolute path", home)
	}
	accountDir := filepath.Join(home, account)
	if _, err := os.Stat(accountDir); err != nil {
		return fmt.Errorf("apple signing requested but the account plugin folder is missing: %s: %w", accountDir, err)
	}
	_ = os.Setenv("APPLE_ACCOUNT", account)
	_ = os.Setenv("APPLE_HOME", home)
	_ = os.Setenv("APPLE_ACCOUNT_DIR", accountDir)
	fmt.Fprintf(os.Stderr, "→ Apple account: %s (%s)\n", account, accountDir)
	return nil
}

// readAppleAccountFile returns the account folder name from the first readable
// config file, or an error naming every path it tried.
func readAppleAccountFile(repoDir string) (string, error) {
	for _, name := range appleAccountFiles {
		b, err := os.ReadFile(filepath.Join(repoDir, name))
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(b), "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			return line, nil
		}
		return "", fmt.Errorf("apple signing requested but %s holds no account name (only blank/comment lines)",
			filepath.Join(repoDir, name))
	}
	return "", fmt.Errorf("apple signing requested but no Apple account resolved: create %s with the account "+
		"plugin folder name, or export APPLE_ACCOUNT / APPLE_ACCOUNT_DIR",
		filepath.Join(repoDir, appleAccountFiles[0]))
}

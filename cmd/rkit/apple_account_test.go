package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeAppleAccountConfig creates repoDir/config/apple-account holding body.
func writeAppleAccountConfig(t *testing.T, repoDir, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(repoDir, "config"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repoDir, "config", "apple-account"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// clearAppleEnv unsets every variable the resolution reads, restoring after.
func clearAppleEnv(t *testing.T) {
	t.Helper()
	for _, k := range []string{"APPLE_ACCOUNT", "APPLE_ACCOUNT_DIR", "APPLE_HOME", "HOME"} {
		t.Setenv(k, "")
		os.Unsetenv(k)
	}
}

// appleHome makes a plugin root holding one folder per account name.
func appleHome(t *testing.T, accounts ...string) string {
	t.Helper()
	home := t.TempDir()
	for _, a := range accounts {
		if err := os.MkdirAll(filepath.Join(home, a), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return home
}

// TestLoadAppleAccountResolvesFromConfig is the happy path: the account name
// comes from config/apple-account and every variable modernech-sign reads is
// exported — including APPLE_HOME, which the shell twin exports and the Go side
// previously did not, so a child process saw two different resolutions.
func TestLoadAppleAccountResolvesFromConfig(t *testing.T) {
	clearAppleEnv(t)
	repo := t.TempDir()
	writeAppleAccountConfig(t, repo, "# the project account\n\nAcmeCorp\n")
	home := appleHome(t, "AcmeCorp")
	t.Setenv("APPLE_HOME", home)

	if err := loadAppleAccount(repo); err != nil {
		t.Fatalf("loadAppleAccount: %v", err)
	}
	if got := os.Getenv("APPLE_ACCOUNT"); got != "AcmeCorp" {
		t.Errorf("APPLE_ACCOUNT = %q, want AcmeCorp", got)
	}
	if got, want := os.Getenv("APPLE_ACCOUNT_DIR"), filepath.Join(home, "AcmeCorp"); got != want {
		t.Errorf("APPLE_ACCOUNT_DIR = %q, want %q", got, want)
	}
	if got := os.Getenv("APPLE_HOME"); got != home {
		t.Errorf("APPLE_HOME = %q, want %q — the Go side must export it too", got, home)
	}
}

// TestLoadAppleAccountHonoursPresetAccount: an operator cutting under a second
// account exports APPLE_ACCOUNT. Go honoured that and the shell overrode it, so
// the same export was respected by `rkit build` and silently ignored by
// release.sh. Go must keep honouring it — and derive the dir from it, not from
// the repo's config file.
func TestLoadAppleAccountHonoursPresetAccount(t *testing.T) {
	clearAppleEnv(t)
	repo := t.TempDir()
	writeAppleAccountConfig(t, repo, "AcmeCorp\n")
	home := appleHome(t, "AcmeCorp", "OtherLLC")
	t.Setenv("APPLE_HOME", home)
	t.Setenv("APPLE_ACCOUNT", "OtherLLC")

	if err := loadAppleAccount(repo); err != nil {
		t.Fatalf("loadAppleAccount: %v", err)
	}
	if got := os.Getenv("APPLE_ACCOUNT"); got != "OtherLLC" {
		t.Errorf("APPLE_ACCOUNT = %q, want the preset OtherLLC", got)
	}
	if got, want := os.Getenv("APPLE_ACCOUNT_DIR"), filepath.Join(home, "OtherLLC"); got != want {
		t.Errorf("APPLE_ACCOUNT_DIR = %q, want %q", got, want)
	}
}

// TestLoadAppleAccountFailsClosed covers every mode that used to return
// silently, leaving the Developer-ID path running with no account plugin — an
// ad-hoc signed build the operator believes is Developer-ID signed.
func TestLoadAppleAccountFailsClosed(t *testing.T) {
	cases := []struct {
		name       string
		config     string // "" = write no config file at all
		appleHome  string // "" = leave APPLE_HOME unset
		wantErrSub string
	}{
		{
			name:       "no config file and no env",
			wantErrSub: "no Apple account resolved",
		},
		{
			name:       "config holds only comments and blanks",
			config:     "# nothing here\n\n   \n",
			appleHome:  "SET",
			wantErrSub: "holds no account name",
		},
		{
			name:       "APPLE_HOME unset — no baked operator layout, and no relative path when HOME is unset",
			config:     "AcmeCorp\n",
			wantErrSub: "APPLE_HOME is not set",
		},
		{
			name:       "APPLE_HOME relative",
			config:     "AcmeCorp\n",
			appleHome:  "Workstation/Apple",
			wantErrSub: "is not an absolute path",
		},
		{
			name:       "account plugin folder missing",
			config:     "MissingAccount\n",
			appleHome:  "SET",
			wantErrSub: "account plugin folder is missing",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			clearAppleEnv(t)
			repo := t.TempDir()
			if c.config != "" {
				writeAppleAccountConfig(t, repo, c.config)
			}
			switch c.appleHome {
			case "":
			case "SET":
				t.Setenv("APPLE_HOME", appleHome(t, "AcmeCorp"))
			default:
				t.Setenv("APPLE_HOME", c.appleHome)
			}

			err := loadAppleAccount(repo)
			if err == nil {
				t.Fatalf("loadAppleAccount returned nil; APPLE_ACCOUNT_DIR=%q", os.Getenv("APPLE_ACCOUNT_DIR"))
			}
			if !strings.Contains(err.Error(), c.wantErrSub) {
				t.Fatalf("error = %v, want it to mention %q", err, c.wantErrSub)
			}
		})
	}
}

// TestLoadAppleAccountCarriesNoOperatorLayout: this repo is PUBLIC. No
// operator's personal directory tree may be baked into its source as a default.
// Scans every non-test source file in the package rather than one named file, so
// the guard survives the code being moved between files (it already moved once,
// from build.go to apple_account.go, when build.go crossed 400 lines).
func TestLoadAppleAccountCarriesNoOperatorLayout(t *testing.T) {
	sources, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	scanned := 0
	for _, path := range sources {
		if strings.HasSuffix(path, "_test.go") {
			continue
		}
		src, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		scanned++
		for _, banned := range []string{`"Workstation"`, "Workstation/Apple"} {
			if strings.Contains(string(src), banned) {
				t.Errorf("%s bakes an operator machine layout (%s) into a public repo — "+
					"APPLE_HOME must come from the environment", path, banned)
			}
		}
	}
	if scanned == 0 {
		t.Fatal("scanned no source files — the glob is wrong, so this guard proves nothing")
	}
}

// TestRunBuildAbortsWhenAppleAccountUnresolved proves the error is not merely
// returned but actually stops the build: runBuild is never reached, so nothing
// is compiled and no ad-hoc artifacts are produced.
func TestRunBuildAbortsWhenAppleAccountUnresolved(t *testing.T) {
	clearAppleEnv(t)
	repo := t.TempDir() // no config/apple-account
	err := runBuild([]string{
		"--component", "cli", "--repo", repo, "--src", repo, "--dispatcher", repo,
		"--public", "--dry-run", "--no-vulncheck",
	})
	if err == nil {
		t.Fatal("rkit build --public with no resolvable Apple account must abort")
	}
	if !strings.Contains(err.Error(), "no Apple account resolved") {
		t.Fatalf("error = %v, want the unresolved-account abort", err)
	}
	if _, statErr := os.Stat(filepath.Join(repo, "dist")); statErr == nil {
		t.Error("the build must abort BEFORE producing artifacts")
	}
}

package register

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeFile(t *testing.T, dir, name, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestLoadR2ConfigFull(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "config.toml", "console_url = \"https://c.example\"\nr2_account_id = \"acct123\"\n")
	writeFile(t, dir, "r2.key", "access_key_id = \"AKID\"\nsecret_access_key = \"SECRET\"\n")

	r, err := LoadR2Config(dir)
	if err != nil {
		t.Fatalf("LoadR2Config: %v", err)
	}
	if r.AccountID != "acct123" || r.AccessKeyID != "AKID" || r.Secret != "SECRET" {
		t.Errorf("parsed: %+v", r)
	}
	if r.Bucket != "downloads" {
		t.Errorf("bucket default: got %q want downloads", r.Bucket)
	}
	if r.Endpoint() != "https://acct123.r2.cloudflarestorage.com" {
		t.Errorf("endpoint: %s", r.Endpoint())
	}
}

func TestLoadR2ConfigMissingKeyErrors(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "config.toml", "r2_account_id = \"acct\"\n")
	// no r2.key
	if _, err := LoadR2Config(dir); err == nil || !strings.Contains(err.Error(), "not configured") {
		t.Errorf("want 'not configured' error, got %v", err)
	}
}

func TestConsoleURLFromEnvOverride(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "config.toml", "console_url = \"https://file.example\"\n")
	t.Setenv("BURROWEE_CONSOLE_URL", "https://env.example")
	u, err := ConsoleURLFrom(dir)
	if err != nil || u != "https://env.example" {
		t.Errorf("got %q err %v", u, err)
	}
}

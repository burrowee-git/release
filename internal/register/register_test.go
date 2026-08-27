package register

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestKeygenThenSignVerifies(t *testing.T) {
	dir := t.TempDir()
	pubB64, err := Keygen(dir)
	if err != nil {
		t.Fatalf("Keygen: %v", err)
	}

	cfg, err := LoadConfig(dir) // reads client.key; console_url may be empty in test
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}

	nonceRaw := []byte("0123456789abcdef0123456789abcdef")
	payload := []byte(`{"component":"edge","version":"v0.1.34"}`)
	sig := cfg.Sign(nonceRaw, payload) // helper on Config: ed25519.Sign(priv, sha256(nonce‖payload))

	pub, _ := base64.StdEncoding.DecodeString(pubB64)
	h := sha256.Sum256(append(append([]byte{}, nonceRaw...), payload...))
	if !ed25519.Verify(ed25519.PublicKey(pub), h[:], sig) {
		t.Fatal("signature does not verify against the printed pubkey")
	}
	// client.key must be 0600.
	fi, _ := os.Stat(filepath.Join(dir, "client.key"))
	if fi.Mode().Perm() != 0o600 {
		t.Errorf("client.key perm = %v want 0600", fi.Mode().Perm())
	}
}

func TestLoadConfigParsesMinimalToml(t *testing.T) {
	dir := t.TempDir()
	_, _ = Keygen(dir)
	os.WriteFile(filepath.Join(dir, "config.toml"),
		[]byte("console_url = \"https://c.example\"\nclient_id = \"release-mini\"\n"), 0o644)
	cfg, err := LoadConfig(dir)
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if cfg.ConsoleURL != "https://c.example" || cfg.ClientID != "release-mini" {
		t.Errorf("parsed: %+v", cfg)
	}
}

// TestRegister_RefusesChannelStampMismatch verifies that Register decodes the
// payload's component/version/channel and refuses locally — before
// fetchNonce ever runs, so a doomed cut doesn't spend a nonce — when the
// stamp's shape disagrees with the claimed channel (spec §4.1, same anchored
// patterns as the console's release.StampMatchesChannel). ConsoleURL is a
// fake, unreachable address; a network call would time out or error
// differently than this check, which returns immediately.
func TestRegister_RefusesChannelStampMismatch(t *testing.T) {
	cases := []struct {
		name    string
		payload string
		wantErr string
	}{
		{
			name:    "stable-shaped stamp claims beta channel",
			payload: `{"component":"cli","version":"v0.1.3.2026.06.21.abc12345","channel":"beta"}`,
			wantErr: "not a beta stamp",
		},
		{
			name:    "beta-shaped stamp claims stable channel",
			payload: `{"component":"cli","version":"v0.1.3.beta.2026.06.21.abc12345","channel":"stable"}`,
			wantErr: "not a stable stamp",
		},
		{
			name:    "beta-shaped stamp with no channel field (defaults to stable)",
			payload: `{"component":"cli","version":"v0.1.3.beta.2026.06.21.abc12345"}`,
			wantErr: "not a stable stamp",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg := Config{ConsoleURL: "https://release-register-test.invalid"}
			err := Register(cfg, []byte(tc.payload), false)
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("Register: got %v, want error containing %q", err, tc.wantErr)
			}
		})
	}
}

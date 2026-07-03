package register

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"os"
	"path/filepath"
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

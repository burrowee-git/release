package register

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Config holds the identity and key material needed to register a build.
type Config struct {
	ConsoleURL string
	ClientID   string
	priv       ed25519.PrivateKey
}

// LoadConfig reads <dir>/config.toml and <dir>/client.key.
// The env var BURROWEE_CONSOLE_URL overrides the console_url in the file.
func LoadConfig(dir string) (Config, error) {
	var cfg Config

	// Read client.key (required).
	keyPath := filepath.Join(dir, "client.key")
	keyData, err := os.ReadFile(keyPath)
	if err != nil {
		return cfg, fmt.Errorf("read client.key: %w", err)
	}
	privBytes, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(keyData)))
	if err != nil {
		return cfg, fmt.Errorf("decode client.key: %w", err)
	}
	if len(privBytes) != ed25519.PrivateKeySize {
		return cfg, fmt.Errorf("client.key: expected %d bytes, got %d", ed25519.PrivateKeySize, len(privBytes))
	}
	cfg.priv = ed25519.PrivateKey(privBytes)

	// Read config.toml via the shared TOML parser (optional — keys may be absent).
	conf, err := parseSimpleTOML(filepath.Join(dir, "config.toml"))
	if err != nil {
		return cfg, fmt.Errorf("read config.toml: %w", err)
	}
	cfg.ConsoleURL = conf["console_url"]
	cfg.ClientID = conf["client_id"]

	// Env override.
	if v := os.Getenv("BURROWEE_CONSOLE_URL"); v != "" {
		cfg.ConsoleURL = v
	}

	return cfg, nil
}

// Sign returns an Ed25519 signature over SHA256(nonceRaw ‖ payload).
func (c Config) Sign(nonceRaw, payload []byte) []byte {
	combined := append(append([]byte{}, nonceRaw...), payload...)
	h := sha256.Sum256(combined)
	return ed25519.Sign(c.priv, h[:])
}

package register

import (
	"bufio"
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

	// Read config.toml (optional — console_url and client_id may be absent).
	tomlPath := filepath.Join(dir, "config.toml")
	if data, err := os.ReadFile(tomlPath); err == nil {
		scanner := bufio.NewScanner(strings.NewReader(string(data)))
		for scanner.Scan() {
			line := strings.TrimSpace(scanner.Text())
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			idx := strings.IndexByte(line, '=')
			if idx < 0 {
				continue
			}
			key := strings.TrimSpace(line[:idx])
			val := strings.TrimSpace(line[idx+1:])
			// Strip surrounding double-quotes.
			if len(val) >= 2 && val[0] == '"' && val[len(val)-1] == '"' {
				val = val[1 : len(val)-1]
			}
			switch key {
			case "console_url":
				cfg.ConsoleURL = val
			case "client_id":
				cfg.ClientID = val
			}
		}
	}

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

package register

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// parseSimpleTOML reads a <key> = "<value>" file (blank lines and #-comments
// skipped, split on the first '=', surrounding double-quotes stripped).
// A missing file yields an empty map and no error.
func parseSimpleTOML(path string) (map[string]string, error) {
	out := map[string]string{}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return out, nil
		}
		return nil, err
	}
	sc := bufio.NewScanner(strings.NewReader(string(data)))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		idx := strings.IndexByte(line, '=')
		if idx < 0 {
			continue
		}
		k := strings.TrimSpace(line[:idx])
		v := strings.TrimSpace(line[idx+1:])
		if len(v) >= 2 && v[0] == '"' && v[len(v)-1] == '"' {
			v = v[1 : len(v)-1]
		}
		out[k] = v
	}
	return out, nil
}

// R2Config holds the R2 S3 credentials + target bucket.
type R2Config struct {
	AccountID   string
	Bucket      string
	AccessKeyID string
	Secret      string
}

// Endpoint returns the R2 S3 endpoint for the account.
func (r R2Config) Endpoint() string {
	return "https://" + r.AccountID + ".r2.cloudflarestorage.com"
}

// r2KeyError returns a clear error for missing/partial r2.key credentials.
// It distinguishes a missing file from a file that exists but is incomplete.
func r2KeyError(keyPath string) error {
	if _, err := os.Stat(keyPath); os.IsNotExist(err) {
		return fmt.Errorf("R2 not configured: create %s with access_key_id and secret_access_key", keyPath)
	}
	return fmt.Errorf("R2 not configured: access_key_id/secret_access_key missing in %s", keyPath)
}

// LoadR2Config reads r2_account_id/r2_bucket from <dir>/config.toml and
// access_key_id/secret_access_key from <dir>/r2.key. Bucket defaults to
// "downloads". Returns a clear "R2 not configured" error if account id,
// access key, or secret is missing.
func LoadR2Config(dir string) (R2Config, error) {
	var r R2Config
	conf, err := parseSimpleTOML(filepath.Join(dir, "config.toml"))
	if err != nil {
		return r, fmt.Errorf("read config.toml: %w", err)
	}
	keys, err := parseSimpleTOML(filepath.Join(dir, "r2.key"))
	if err != nil {
		return r, fmt.Errorf("read r2.key: %w", err)
	}
	r.AccountID = conf["r2_account_id"]
	r.Bucket = conf["r2_bucket"]
	if r.Bucket == "" {
		r.Bucket = "downloads"
	}
	r.AccessKeyID = keys["access_key_id"]
	r.Secret = keys["secret_access_key"]

	switch {
	case r.AccountID == "":
		return r, fmt.Errorf("R2 not configured: r2_account_id missing in %s/config.toml", dir)
	case r.AccessKeyID == "" || r.Secret == "":
		return r, r2KeyError(filepath.Join(dir, "r2.key"))
	}
	return r, nil
}

// ConsoleURLFrom reads console_url from <dir>/config.toml, with the
// BURROWEE_CONSOLE_URL env var taking precedence. Errors if empty.
func ConsoleURLFrom(dir string) (string, error) {
	conf, err := parseSimpleTOML(filepath.Join(dir, "config.toml"))
	if err != nil {
		return "", fmt.Errorf("read config.toml: %w", err)
	}
	u := conf["console_url"]
	if v := os.Getenv("BURROWEE_CONSOLE_URL"); v != "" {
		u = v
	}
	if u == "" {
		return "", fmt.Errorf("console_url not configured (set it in %s/config.toml or BURROWEE_CONSOLE_URL)", dir)
	}
	return u, nil
}

// LoadPublishConfig reads config.toml and r2.key once and returns the console
// URL and R2 credentials needed by the publish command. The BURROWEE_CONSOLE_URL
// env var overrides console_url. Returns a clear error if any required field is
// missing.
func LoadPublishConfig(dir string) (consoleURL string, r2 R2Config, err error) {
	conf, err := parseSimpleTOML(filepath.Join(dir, "config.toml"))
	if err != nil {
		return "", r2, fmt.Errorf("read config.toml: %w", err)
	}
	keys, err := parseSimpleTOML(filepath.Join(dir, "r2.key"))
	if err != nil {
		return "", r2, fmt.Errorf("read r2.key: %w", err)
	}

	consoleURL = conf["console_url"]
	if v := os.Getenv("BURROWEE_CONSOLE_URL"); v != "" {
		consoleURL = v
	}
	if consoleURL == "" {
		return "", r2, fmt.Errorf("console_url not configured (set it in %s/config.toml or BURROWEE_CONSOLE_URL)", dir)
	}

	r2.AccountID = conf["r2_account_id"]
	r2.Bucket = conf["r2_bucket"]
	if r2.Bucket == "" {
		r2.Bucket = "downloads"
	}
	r2.AccessKeyID = keys["access_key_id"]
	r2.Secret = keys["secret_access_key"]

	switch {
	case r2.AccountID == "":
		return "", r2, fmt.Errorf("R2 not configured: r2_account_id missing in %s/config.toml", dir)
	case r2.AccessKeyID == "" || r2.Secret == "":
		return "", r2, r2KeyError(filepath.Join(dir, "r2.key"))
	}
	return consoleURL, r2, nil
}

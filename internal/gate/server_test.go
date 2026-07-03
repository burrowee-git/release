package gate

import (
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

// newTestRegistry creates a temp sqlite db with the exact schema, inserts the
// raw-32-byte pubkey for the given public key, then opens it via OpenRegistry.
func newTestRegistry(t *testing.T, pub ed25519.PublicKey) *Registry {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "reg.db")

	h, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("newTestRegistry: open: %v", err)
	}
	_, err = h.Exec(`CREATE TABLE pubkeys(fingerprint TEXT PRIMARY KEY, pubkey BLOB NOT NULL, label TEXT, added_at INTEGER)`)
	if err != nil {
		t.Fatalf("newTestRegistry: create table: %v", err)
	}
	fp := Fingerprint(pub)
	_, err = h.Exec(`INSERT INTO pubkeys(fingerprint,pubkey,label,added_at) VALUES(?,?,?,0)`, fp, []byte(pub), "test")
	if err != nil {
		t.Fatalf("newTestRegistry: insert: %v", err)
	}
	if err := h.Close(); err != nil {
		t.Fatalf("newTestRegistry: close setup db: %v", err)
	}

	reg, err := OpenRegistry(dbPath)
	if err != nil {
		t.Fatalf("newTestRegistry: OpenRegistry: %v", err)
	}
	t.Cleanup(func() { reg.Close() })
	return reg
}

// sign signs the nonce+":"+path with the given private key and returns the
// base64-STD-encoded signature.
func sign(t *testing.T, priv ed25519.PrivateKey, nonce, path string) string {
	t.Helper()
	return base64.StdEncoding.EncodeToString(ed25519.Sign(priv, []byte(nonce+":"+path)))
}

// getChallenge fetches a nonce from /relay/challenge and returns it.
func getChallenge(t *testing.T, baseURL string) string {
	t.Helper()
	resp, err := http.Get(baseURL + "/relay/challenge")
	if err != nil {
		t.Fatalf("GET /relay/challenge: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /relay/challenge: status %d", resp.StatusCode)
	}
	var ch struct {
		Nonce string `json:"nonce"`
		Exp   int64  `json:"exp"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&ch); err != nil {
		t.Fatalf("decode challenge: %v", err)
	}
	if ch.Nonce == "" {
		t.Fatal("challenge nonce is empty")
	}
	if ch.Exp == 0 {
		t.Fatal("challenge exp is zero")
	}
	return ch.Nonce
}

// newTestServer sets up a temp releases dir with latest.txt="hello", a registry
// with the generated pubkey, and returns the httptest server + public + private keys.
func newTestServer(t *testing.T) (*httptest.Server, ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "latest.txt"), []byte("hello"), 0644); err != nil {
		t.Fatalf("write latest.txt: %v", err)
	}
	reg := newTestRegistry(t, pub)
	ts := httptest.NewServer(NewServer(reg, dir).Handler())
	t.Cleanup(ts.Close)
	return ts, pub, priv
}

func TestGateHappyPath(t *testing.T) {
	ts, pub, priv := newTestServer(t)

	nonce := getChallenge(t, ts.URL)
	path := "/relay/release/latest.txt"

	req, err := http.NewRequest("GET", ts.URL+path, nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("X-Burrowee-Key-FP", Fingerprint(pub))
	req.Header.Set("X-Burrowee-Nonce", nonce)
	req.Header.Set("X-Burrowee-Sig", sign(t, priv, nonce, path))

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("want 200 got %d", resp.StatusCode)
	}
	b, _ := io.ReadAll(resp.Body)
	if string(b) != "hello" {
		t.Fatalf("body=%q want %q", string(b), "hello")
	}
}

func TestGateChallengeExpField(t *testing.T) {
	ts, _, _ := newTestServer(t)

	resp, err := http.Get(ts.URL + "/relay/challenge")
	if err != nil {
		t.Fatalf("GET /relay/challenge: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("want 200 got %d", resp.StatusCode)
	}
	var ch struct {
		Nonce string `json:"nonce"`
		Exp   int64  `json:"exp"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&ch); err != nil {
		t.Fatalf("decode: %v", err)
	}
	// exp should be ~2 minutes from now.
	now := time.Now().Unix()
	if ch.Exp < now+100 || ch.Exp > now+200 {
		t.Fatalf("exp=%d, expected ~now+120 (got delta %d)", ch.Exp, ch.Exp-now)
	}
}

func TestGateUnknownFP(t *testing.T) {
	ts, _, priv := newTestServer(t)

	// Generate a different key — its FP will not be in the registry.
	otherPub, _, _ := ed25519.GenerateKey(rand.Reader)

	nonce := getChallenge(t, ts.URL)
	path := "/relay/release/latest.txt"

	req, _ := http.NewRequest("GET", ts.URL+path, nil)
	req.Header.Set("X-Burrowee-Key-FP", Fingerprint(otherPub))
	req.Header.Set("X-Burrowee-Nonce", nonce)
	req.Header.Set("X-Burrowee-Sig", sign(t, priv, nonce, path))

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("want 401 got %d", resp.StatusCode)
	}
}

func TestGateBadSig(t *testing.T) {
	ts, pub, _ := newTestServer(t)

	nonce := getChallenge(t, ts.URL)
	path := "/relay/release/latest.txt"

	// Sign with a different key so sig is structurally valid but wrong.
	_, wrongPriv, _ := ed25519.GenerateKey(rand.Reader)

	req, _ := http.NewRequest("GET", ts.URL+path, nil)
	req.Header.Set("X-Burrowee-Key-FP", Fingerprint(pub))
	req.Header.Set("X-Burrowee-Nonce", nonce)
	req.Header.Set("X-Burrowee-Sig", sign(t, wrongPriv, nonce, path))

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("want 401 got %d", resp.StatusCode)
	}
}

func TestGateBadSigBase64(t *testing.T) {
	ts, pub, _ := newTestServer(t)

	nonce := getChallenge(t, ts.URL)
	path := "/relay/release/latest.txt"

	req, _ := http.NewRequest("GET", ts.URL+path, nil)
	req.Header.Set("X-Burrowee-Key-FP", Fingerprint(pub))
	req.Header.Set("X-Burrowee-Nonce", nonce)
	req.Header.Set("X-Burrowee-Sig", "!!!not-valid-base64!!!")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("want 401 got %d", resp.StatusCode)
	}
}

func TestGateReplayNonce(t *testing.T) {
	ts, pub, priv := newTestServer(t)

	nonce := getChallenge(t, ts.URL)
	path := "/relay/release/latest.txt"

	doRequest := func() *http.Response {
		req, _ := http.NewRequest("GET", ts.URL+path, nil)
		req.Header.Set("X-Burrowee-Key-FP", Fingerprint(pub))
		req.Header.Set("X-Burrowee-Nonce", nonce)
		req.Header.Set("X-Burrowee-Sig", sign(t, priv, nonce, path))
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("request: %v", err)
		}
		return resp
	}

	// First use: should succeed.
	resp := doRequest()
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("first use: want 200 got %d", resp.StatusCode)
	}

	// Second use of the same nonce: must be 403.
	resp = doRequest()
	resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("replay: want 403 got %d", resp.StatusCode)
	}
}

func TestGateMissingHeaders(t *testing.T) {
	ts, pub, priv := newTestServer(t)
	nonce := getChallenge(t, ts.URL)
	path := "/relay/release/latest.txt"

	cases := []struct {
		name string
		fp   string
		nc   string
		sig  string
	}{
		{"missing_fp", "", nonce, sign(t, priv, nonce, path)},
		{"missing_nonce", Fingerprint(pub), "", sign(t, priv, nonce, path)},
		{"missing_sig", Fingerprint(pub), nonce, ""},
		{"missing_all", "", "", ""},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req, _ := http.NewRequest("GET", ts.URL+path, nil)
			if tc.fp != "" {
				req.Header.Set("X-Burrowee-Key-FP", tc.fp)
			}
			if tc.nc != "" {
				req.Header.Set("X-Burrowee-Nonce", tc.nc)
			}
			if tc.sig != "" {
				req.Header.Set("X-Burrowee-Sig", tc.sig)
			}
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatalf("request: %v", err)
			}
			resp.Body.Close()
			if resp.StatusCode != http.StatusUnauthorized {
				t.Fatalf("want 401 got %d", resp.StatusCode)
			}
		})
	}
}

func TestGateTraversal(t *testing.T) {
	ts, pub, priv := newTestServer(t)

	traversalPaths := []string{
		"/relay/release/../latest.txt",
		"/relay/release/../../etc/passwd",
		"/relay/release/%2e%2e/latest.txt",
		"/relay/release/sub/../../latest.txt",
	}

	for _, path := range traversalPaths {
		t.Run(path, func(t *testing.T) {
			nonce := getChallenge(t, ts.URL)
			req, _ := http.NewRequest("GET", ts.URL+path, nil)
			req.Header.Set("X-Burrowee-Key-FP", Fingerprint(pub))
			req.Header.Set("X-Burrowee-Nonce", nonce)
			req.Header.Set("X-Burrowee-Sig", sign(t, priv, nonce, path))

			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatalf("request: %v", err)
			}
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				t.Fatalf("traversal %q: want 404/403 got %d", path, resp.StatusCode)
			}
		})
	}
}

func TestGateRateLimit(t *testing.T) {
	ts, pub, priv := newTestServer(t)

	path := "/relay/release/latest.txt"
	fp := Fingerprint(pub)

	// Pre-fetch all nonces using distinct X-Forwarded-For IPs so we do not
	// exhaust the per-IP challenge limiter before reaching the download limiter.
	const total = 62
	nonces := make([]string, total)
	for i := range nonces {
		req, _ := http.NewRequest("GET", ts.URL+"/relay/challenge", nil)
		req.Header.Set("X-Forwarded-For", "10.0.0."+string(rune('1'+i%25))) // 25 distinct IPs
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("challenge %d: %v", i, err)
		}
		var ch struct {
			Nonce string `json:"nonce"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&ch); err != nil {
			resp.Body.Close()
			t.Fatalf("challenge %d decode: %v", i, err)
		}
		resp.Body.Close()
		nonces[i] = ch.Nonce
	}

	// Now exhaust the download limiter. All requests use the same FP bucket.
	var lastStatus int
	for i, nonce := range nonces {
		req, _ := http.NewRequest("GET", ts.URL+path, nil)
		req.Header.Set("X-Burrowee-Key-FP", fp)
		req.Header.Set("X-Burrowee-Nonce", nonce)
		req.Header.Set("X-Burrowee-Sig", sign(t, priv, nonce, path))
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("download %d: %v", i, err)
		}
		resp.Body.Close()
		lastStatus = resp.StatusCode
		if resp.StatusCode == http.StatusTooManyRequests {
			return // hit the download rate limit — expected
		}
	}
	t.Fatalf("expected 429 after exhausting download rate limit, last status %d", lastStatus)
}

func TestGateChallengeRateLimit(t *testing.T) {
	ts, _, _ := newTestServer(t)

	// Exhaust the challenge limiter for this IP (default 60/min).
	var lastStatus int
	for i := 0; i < 62; i++ {
		resp, err := http.Get(ts.URL + "/relay/challenge")
		if err != nil {
			t.Fatalf("request %d: %v", i, err)
		}
		resp.Body.Close()
		lastStatus = resp.StatusCode
		if resp.StatusCode == http.StatusTooManyRequests {
			return
		}
	}
	t.Fatalf("expected 429 from challenge limiter, last status %d", lastStatus)
}

func TestGateFileNotFound(t *testing.T) {
	ts, pub, priv := newTestServer(t)

	nonce := getChallenge(t, ts.URL)
	path := "/relay/release/nonexistent.txt"

	req, _ := http.NewRequest("GET", ts.URL+path, nil)
	req.Header.Set("X-Burrowee-Key-FP", Fingerprint(pub))
	req.Header.Set("X-Burrowee-Nonce", nonce)
	req.Header.Set("X-Burrowee-Sig", sign(t, priv, nonce, path))

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("want 404 got %d", resp.StatusCode)
	}
}

// newTestServerRaw returns a Server (not wrapped in httptest.Server) plus the
// releases dir, pub, and priv so callers can call handler methods directly.
func newTestServerRaw(t *testing.T) (*Server, string, ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "latest.txt"), []byte("hello"), 0644); err != nil {
		t.Fatalf("write latest.txt: %v", err)
	}
	reg := newTestRegistry(t, pub)
	srv := NewServer(reg, dir)
	return srv, dir, pub, priv
}

// TestPathSafetyTraversalValidSig exercises the path-safety block (server.go
// ~137-152) directly with a VALID signature — bypassing http.ServeMux, which
// would clean the path before the handler sees it.
//
// Proof the block is what rejects: we place a real file at the parent of
// releasesDir so a successful traversal WOULD serve it.  The test asserts 404,
// not 401 (which would indicate Verify failed instead of the path check).
func TestPathSafetyTraversalValidSig(t *testing.T) {
	srv, releasesDir, pub, priv := newTestServerRaw(t)

	// Place a file OUTSIDE releasesDir that a traversal would reach.
	parent := filepath.Dir(releasesDir)
	outsideFile := filepath.Join(parent, "registry.db")
	if err := os.WriteFile(outsideFile, []byte("secret"), 0644); err != nil {
		t.Fatalf("write outside file: %v", err)
	}

	// Construct a path whose literal string contains "..".
	// net/http.NewRequest would clean the URL, so set URL.Path directly.
	traversalPath := "/relay/release/../registry.db"
	req := httptest.NewRequest("GET", "http://localhost"+traversalPath, nil)
	// Override the cleaned path with the raw traversal string.
	req.URL.Path = traversalPath

	// Issue a nonce from the store directly (no HTTP round-trip needed).
	nonce := srv.nonces.Issue()

	req.Header.Set("X-Burrowee-Key-FP", Fingerprint(pub))
	req.Header.Set("X-Burrowee-Nonce", nonce)
	req.Header.Set("X-Burrowee-Sig", sign(t, priv, nonce, traversalPath))

	rec := httptest.NewRecorder()
	srv.handleDownload(rec, req)

	got := rec.Code
	if got != http.StatusNotFound {
		t.Fatalf("want 404 (path-safety block), got %d — if 401, Verify failed instead of path check", got)
	}
}

// TestPathSafetySymlinkEscape exercises the EvalSymlinks re-containment check
// (server.go ~155-169). A symlink inside releasesDir that points outside must
// be rejected (404), while a real in-dir file must succeed (200).
func TestPathSafetySymlinkEscape(t *testing.T) {
	srv, releasesDir, pub, priv := newTestServerRaw(t)

	// Place a file OUTSIDE releasesDir that the symlink will point to.
	parent := filepath.Dir(releasesDir)
	outsideFile := filepath.Join(parent, "secret.txt")
	if err := os.WriteFile(outsideFile, []byte("secret"), 0644); err != nil {
		t.Fatalf("write outside file: %v", err)
	}

	// Create a symlink inside releasesDir pointing to the outside file.
	symlinkName := "escape.txt"
	symlinkPath := filepath.Join(releasesDir, symlinkName)
	if err := os.Symlink(outsideFile, symlinkPath); err != nil {
		t.Fatalf("create symlink: %v", err)
	}

	t.Run("symlink_escape_rejected_404", func(t *testing.T) {
		requestPath := "/relay/release/" + symlinkName
		req := httptest.NewRequest("GET", "http://localhost"+requestPath, nil)
		req.URL.Path = requestPath

		nonce := srv.nonces.Issue()
		req.Header.Set("X-Burrowee-Key-FP", Fingerprint(pub))
		req.Header.Set("X-Burrowee-Nonce", nonce)
		req.Header.Set("X-Burrowee-Sig", sign(t, priv, nonce, requestPath))

		rec := httptest.NewRecorder()
		srv.handleDownload(rec, req)

		if rec.Code != http.StatusNotFound {
			t.Fatalf("symlink escape: want 404, got %d", rec.Code)
		}
	})

	t.Run("legit_in_dir_file_200", func(t *testing.T) {
		requestPath := "/relay/release/latest.txt"
		req := httptest.NewRequest("GET", "http://localhost"+requestPath, nil)
		req.URL.Path = requestPath

		nonce := srv.nonces.Issue()
		req.Header.Set("X-Burrowee-Key-FP", Fingerprint(pub))
		req.Header.Set("X-Burrowee-Nonce", nonce)
		req.Header.Set("X-Burrowee-Sig", sign(t, priv, nonce, requestPath))

		rec := httptest.NewRecorder()
		srv.handleDownload(rec, req)

		if rec.Code != http.StatusOK {
			t.Fatalf("legit file: want 200, got %d", rec.Code)
		}
		if body := rec.Body.String(); body != "hello" {
			t.Fatalf("legit file: body=%q want %q", body, "hello")
		}
	})
}

package gate

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Server wires the registry, nonce store, and rate limiters into the
// challenge + gated-download HTTP handler pair.
type Server struct {
	reg         *Registry
	releasesDir string
	nonces      *NonceStore
	dlLimiter   *Limiter
	chLimiter   *Limiter
}

// NewServer returns a Server that uses reg for fingerprint → pubkey lookups and
// serves files from releasesDir. It wires its own NonceStore (2 min TTL), a
// download Limiter (60 rpm per fingerprint), and a challenge Limiter (60 rpm
// per client IP).
func NewServer(reg *Registry, releasesDir string) *Server {
	return &Server{
		reg:         reg,
		releasesDir: releasesDir,
		nonces:      NewNonceStore(2 * time.Minute),
		dlLimiter:   NewLimiter(60),
		chLimiter:   NewLimiter(60),
	}
}

// Handler returns an http.Handler routing GET /relay/challenge and
// GET /relay/release/ to the respective handlers.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /relay/challenge", s.handleChallenge)
	mux.HandleFunc("GET /relay/release/", s.handleDownload)
	return mux
}

// clientIP returns the client IP from X-Forwarded-For (nginx sets this to the
// real client) when present, otherwise the host part of r.RemoteAddr.
//
// SECURITY INVARIANT: this trusts X-Forwarded-For unconditionally and is only
// safe behind a trusted reverse proxy that *sets* (not appends) XFF to the real
// client IP. The deployed topology binds this gate to 127.0.0.1 with nginx in
// front (see ops/), so an external client cannot reach it directly to spoof the
// header. Do NOT expose this listener publicly, and do NOT configure nginx to
// append rather than overwrite XFF — either lets a client forge the value the
// challenge rate-limiter keys on and mint a fresh per-IP bucket per request.
func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		// X-Forwarded-For may be comma-separated; take the first entry.
		if i := strings.IndexByte(xff, ','); i != -1 {
			xff = xff[:i]
		}
		return strings.TrimSpace(xff)
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// handleChallenge is the unauthenticated nonce-issuance endpoint.
// Rate-limited by client IP (60 rpm). Returns JSON {"nonce":"<b64>","exp":<unix>}.
func (s *Server) handleChallenge(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if !s.chLimiter.Allow(ip) {
		http.Error(w, "rate limit exceeded", http.StatusTooManyRequests)
		return
	}
	nonce := s.nonces.Issue()
	exp := time.Now().Add(2 * time.Minute).Unix()
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(struct {
		Nonce string `json:"nonce"`
		Exp   int64  `json:"exp"`
	}{nonce, exp})
}

// handleDownload is the gated file-download endpoint.
// Fail-closed; see inline comments for the security-critical ordering.
func (s *Server) handleDownload(w http.ResponseWriter, r *http.Request) {
	// Step 1: Read the 3 required headers. Any missing → 401.
	fp := r.Header.Get("X-Burrowee-Key-FP")
	nonce := r.Header.Get("X-Burrowee-Nonce")
	sigHeader := r.Header.Get("X-Burrowee-Sig")
	if fp == "" || nonce == "" || sigHeader == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	// Step 2: Rate-limit by fingerprint → 429.
	if !s.dlLimiter.Allow(fp) {
		http.Error(w, "rate limit exceeded", http.StatusTooManyRequests)
		return
	}

	// Step 3: Resolve pubkey by fingerprint → miss → 401.
	pub, ok, err := s.reg.Lookup(fp)
	if err != nil || !ok {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	// Step 4: base64-std-decode the signature → decode error → 401.
	sig, err := base64.StdEncoding.DecodeString(sigHeader)
	if err != nil {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	// Step 5: Consume the nonce → false → 403.
	// Consume happens AFTER lookup+sig-decode but BEFORE Verify. This is
	// deliberate: a Verify failure still burns the nonce, preventing the gate
	// from acting as a nonce-validity oracle (an attacker cannot probe "did I
	// format the sig correctly?" without paying one nonce per attempt).
	if !s.nonces.Consume(nonce) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}

	// Step 6: Verify the signature over exact bytes nonce+":"+r.URL.Path → false → 401.
	// NOTE: the nonce was already consumed in step 5; a Verify failure here still
	// burns the nonce (see comment above).
	if !ed25519.Verify(pub, []byte(nonce+":"+r.URL.Path), sig) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	// Step 7: Resolve the file path safely — reject traversal.
	const prefix = "/relay/release/"
	rel := strings.TrimPrefix(r.URL.Path, prefix)

	// Reject explicit traversal components or absolute paths.
	if strings.Contains(rel, "..") || filepath.IsAbs(rel) || rel == "" {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}

	// Resolve absolute path and confirm it stays inside releasesDir.
	abs := filepath.Join(s.releasesDir, filepath.Clean(rel))
	absReleases := filepath.Clean(s.releasesDir)

	// filepath.Rel containment check: the result must not start with ".." and
	// must not itself be absolute (which would indicate a different root).
	relCheck, err := filepath.Rel(absReleases, abs)
	if err != nil || strings.HasPrefix(relCheck, "..") || filepath.IsAbs(relCheck) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}

	// Symlink-escape defence: resolve any symlinks and re-check containment.
	realAbs, err := filepath.EvalSymlinks(abs)
	if err != nil {
		// File does not exist (or is inaccessible).
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	realReleases, err := filepath.EvalSymlinks(absReleases)
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	relCheck2, err := filepath.Rel(realReleases, realAbs)
	if err != nil || strings.HasPrefix(relCheck2, "..") || filepath.IsAbs(relCheck2) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}

	// Step 8: Open and stream the file.
	f, err := os.Open(realAbs)
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	defer f.Close()

	fi, err := f.Stat()
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}

	http.ServeContent(w, r, fi.Name(), fi.ModTime(), f)
}

package r2

import (
	"net/http"
	"regexp"
	"strings"
	"testing"
	"time"
)

func newPutReq(t *testing.T, body []byte) *http.Request {
	t.Helper()
	req, err := http.NewRequest(http.MethodPut, "https://acct.r2.cloudflarestorage.com/downloads/cli/v1/x.zip", strings.NewReader(string(body)))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/zip")
	return req
}

func TestSignV4DeterministicAndBindsBody(t *testing.T) {
	now := time.Date(2026, 6, 19, 12, 0, 0, 0, time.UTC)

	r1 := newPutReq(t, []byte("abc"))
	signV4(r1, "AKID", "SECRET", "auto", "s3", []byte("abc"), now)
	a1 := r1.Header.Get("Authorization")

	// Deterministic: same inputs+clock → identical signature.
	r2req := newPutReq(t, []byte("abc"))
	signV4(r2req, "AKID", "SECRET", "auto", "s3", []byte("abc"), now)
	if a1 != r2req.Header.Get("Authorization") {
		t.Fatal("signature not deterministic for fixed clock")
	}

	// Header values.
	if r1.Header.Get("X-Amz-Date") != "20260619T120000Z" {
		t.Errorf("X-Amz-Date: got %q", r1.Header.Get("X-Amz-Date"))
	}
	if got := r1.Header.Get("X-Amz-Content-Sha256"); got != hashHex([]byte("abc")) {
		t.Errorf("content-sha256: got %q", got)
	}
	// Format: scope + 64-hex signature.
	if !strings.HasPrefix(a1, "AWS4-HMAC-SHA256 Credential=AKID/20260619/auto/s3/aws4_request, SignedHeaders=") {
		t.Errorf("authz prefix wrong: %q", a1)
	}
	if !regexp.MustCompile(`Signature=[0-9a-f]{64}$`).MatchString(a1) {
		t.Errorf("authz signature not 64 hex: %q", a1)
	}

	// Body-sensitive: a different body → different signature.
	r3 := newPutReq(t, []byte("xyz"))
	signV4(r3, "AKID", "SECRET", "auto", "s3", []byte("xyz"), now)
	if r3.Header.Get("Authorization") == a1 {
		t.Error("signature did not change with body")
	}
}

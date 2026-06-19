package r2

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
)

type fakeDoer struct {
	got     *http.Request
	gotBody []byte
	status  int
}

func (f *fakeDoer) Do(req *http.Request) (*http.Response, error) {
	f.got = req
	if req.Body != nil {
		f.gotBody, _ = io.ReadAll(req.Body)
	}
	st := f.status
	if st == 0 {
		st = 200
	}
	return &http.Response{StatusCode: st, Body: io.NopCloser(bytes.NewReader([]byte("ok")))}, nil
}

func TestPutSignsAndSends(t *testing.T) {
	f := &fakeDoer{}
	c := New("acct", "downloads", "AKID", "SECRET", f)
	if err := c.Put(context.Background(), "cli/v1/x.zip", []byte("data"), "application/zip"); err != nil {
		t.Fatalf("Put: %v", err)
	}
	if f.got.Method != http.MethodPut {
		t.Errorf("method: %s", f.got.Method)
	}
	if f.got.URL.String() != "https://acct.r2.cloudflarestorage.com/downloads/cli/v1/x.zip" {
		t.Errorf("url: %s", f.got.URL.String())
	}
	authz := f.got.Header.Get("Authorization")
	if authz == "" || f.got.Header.Get("X-Amz-Content-Sha256") == "" {
		t.Error("missing sigv4 headers")
	}
	if !strings.HasPrefix(authz, "AWS4-HMAC-SHA256 Credential=AKID/") {
		t.Errorf("Authorization missing expected prefix: %s", authz)
	}
	if !strings.Contains(authz, "/auto/s3/aws4_request") {
		t.Errorf("Authorization missing scope: %s", authz)
	}
	if f.got.Header.Get("X-Amz-Date") == "" {
		t.Error("missing X-Amz-Date header")
	}
	if f.got.Header.Get("Content-Type") != "application/zip" {
		t.Errorf("content-type: %s", f.got.Header.Get("Content-Type"))
	}
	if string(f.gotBody) != "data" {
		t.Errorf("body: %s", f.gotBody)
	}
}

func TestPutNon2xxErrors(t *testing.T) {
	c := New("acct", "downloads", "AKID", "SECRET", &fakeDoer{status: 403})
	if err := c.Put(context.Background(), "k", []byte("d"), "application/zip"); err == nil {
		t.Fatal("expected error on 403")
	}
}

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

// scriptedDoer returns canned responses in order and records every request URL,
// so List's continuation-token loop can be exercised across two pages.
type scriptedDoer struct {
	bodies []string
	urls   []string
	i      int
}

func (d *scriptedDoer) Do(req *http.Request) (*http.Response, error) {
	d.urls = append(d.urls, req.URL.String())
	body := d.bodies[d.i]
	if d.i < len(d.bodies)-1 {
		d.i++
	}
	return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body))}, nil
}

func TestListSignsAndPaginates(t *testing.T) {
	page1 := `<ListBucketResult><Contents><Key>relay/v1/a.zip</Key></Contents>` +
		`<IsTruncated>true</IsTruncated><NextContinuationToken>TOK</NextContinuationToken></ListBucketResult>`
	page2 := `<ListBucketResult><Contents><Key>relay/v2/b.zip</Key></Contents>` +
		`<IsTruncated>false</IsTruncated></ListBucketResult>`
	d := &scriptedDoer{bodies: []string{page1, page2}}
	c := New("acct", "downloads", "AKID", "SECRET", d)

	keys, err := c.List(context.Background(), "relay/")
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(keys) != 2 || keys[0] != "relay/v1/a.zip" || keys[1] != "relay/v2/b.zip" {
		t.Errorf("keys: %v", keys)
	}
	if len(d.urls) != 2 {
		t.Fatalf("want 2 requests (paginated), got %d: %v", len(d.urls), d.urls)
	}
	if !strings.HasPrefix(d.urls[0], "https://acct.r2.cloudflarestorage.com/downloads?") {
		t.Errorf("list url: %s", d.urls[0])
	}
	if !strings.Contains(d.urls[0], "list-type=2") || !strings.Contains(d.urls[0], "prefix=relay") {
		t.Errorf("list url missing query: %s", d.urls[0])
	}
	if !strings.Contains(d.urls[1], "continuation-token=TOK") {
		t.Errorf("page 2 missing continuation token: %s", d.urls[1])
	}
}

func TestListEncodesSpaceAsPercent20(t *testing.T) {
	// SigV4 signs req.URL.RawQuery verbatim, so the query must encode spaces as
	// %20 (not '+') or the signature won't match S3/R2's canonicalization.
	body := `<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>`
	d := &scriptedDoer{bodies: []string{body}}
	c := New("acct", "downloads", "AKID", "SECRET", d)
	if _, err := c.List(context.Background(), "a b/"); err != nil {
		t.Fatalf("List: %v", err)
	}
	if !strings.Contains(d.urls[0], "prefix=a%20b") {
		t.Errorf("space must encode as %%20: %s", d.urls[0])
	}
	if strings.Contains(d.urls[0], "prefix=a+b") {
		t.Errorf("space encoded as '+' (breaks SigV4): %s", d.urls[0])
	}
}

func TestListErrorsOnNon2xx(t *testing.T) {
	c := New("acct", "downloads", "AKID", "SECRET", &fakeDoer{status: 403})
	if _, err := c.List(context.Background(), "relay/"); err == nil {
		t.Fatal("expected error on 403")
	}
}

func TestDeleteSignsAndSends(t *testing.T) {
	f := &fakeDoer{status: 204}
	c := New("acct", "downloads", "AKID", "SECRET", f)
	if err := c.Delete(context.Background(), "relay/v1/a.zip"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if f.got.Method != http.MethodDelete {
		t.Errorf("method: %s", f.got.Method)
	}
	if f.got.URL.String() != "https://acct.r2.cloudflarestorage.com/downloads/relay/v1/a.zip" {
		t.Errorf("url: %s", f.got.URL.String())
	}
	authz := f.got.Header.Get("Authorization")
	if !strings.HasPrefix(authz, "AWS4-HMAC-SHA256 Credential=AKID/") || !strings.Contains(authz, "/auto/s3/aws4_request") {
		t.Errorf("Authorization missing expected prefix/scope: %s", authz)
	}
	if f.got.Header.Get("X-Amz-Date") == "" || f.got.Header.Get("X-Amz-Content-Sha256") == "" {
		t.Error("missing sigv4 headers")
	}
}

func TestDeleteAbsentKeyIsNoOp(t *testing.T) {
	c := New("acct", "downloads", "AKID", "SECRET", &fakeDoer{status: 404})
	if err := c.Delete(context.Background(), "relay/gone.zip"); err != nil {
		t.Errorf("404 should be a no-op, got: %v", err)
	}
}

func TestDeleteNon2xxErrors(t *testing.T) {
	c := New("acct", "downloads", "AKID", "SECRET", &fakeDoer{status: 403})
	if err := c.Delete(context.Background(), "k"); err == nil {
		t.Fatal("expected error on 403")
	}
}

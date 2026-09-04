package r2

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
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

func TestGetSignsAndSends(t *testing.T) {
	f := &fakeDoer{status: 200}
	c := New("acct", "downloads", "AKID", "SECRET", f)
	body, err := c.Get(context.Background(), "relay/v1/a.zip")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if f.got.Method != http.MethodGet {
		t.Errorf("method: %s", f.got.Method)
	}
	if f.got.URL.String() != "https://acct.r2.cloudflarestorage.com/downloads/relay/v1/a.zip" {
		t.Errorf("url: %s", f.got.URL.String())
	}
	if f.got.URL.Path != "/downloads/relay/v1/a.zip" {
		t.Errorf("path: %s", f.got.URL.Path)
	}
	if f.got.Header.Get("Authorization") == "" {
		t.Error("missing Authorization header (sigv4 not signed)")
	}
	if string(body) != "ok" {
		t.Errorf("body: %s", body)
	}
}

func TestGetNon2xxErrors(t *testing.T) {
	c := New("acct", "downloads", "AKID", "SECRET", &fakeDoer{status: 404})
	body, err := c.Get(context.Background(), "relay/gone.zip")
	if err == nil {
		t.Fatal("expected error on 404, got nil (would silently publish empty bytes)")
	}
	if body != nil {
		t.Errorf("expected nil body on error, got %q", body)
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

// --- transport policy --------------------------------------------------------
//
// These pin the 2026-09-03 regression. The package used to hang a flat 30s
// timeout on the http.Client, which covers the body write too, so a 15.9MB
// component zip could only be published from a link doing 530KB/s or better.
// Three beta cuts died at publish-dir's first PUT with `context deadline
// exceeded` while the bucket and the credential were both fine.
//
// The tests below use a deliberately short phase so a real server can outlast
// it in milliseconds; the production value is phaseTimeout.

const (
	testPhase = 500 * time.Millisecond
	testSlow  = 3 * testPhase // comfortably past the phase, still a fast test
)

func TestDefaultClientCarriesNoWholeRequestTimeout(t *testing.T) {
	// A whole-request clock is what capped object size. If one comes back, the
	// size ceiling comes back with it, silently.
	if got := newHTTPClient().Timeout; got != 0 {
		t.Errorf("http.Client.Timeout = %v, want 0: a whole-request clock caps how large an object can be moved", got)
	}
}

func TestTransportBoundsEveryNonTransferPhase(t *testing.T) {
	tr := newTransport(testPhase)
	if tr.TLSHandshakeTimeout != testPhase {
		t.Errorf("TLSHandshakeTimeout = %v, want %v", tr.TLSHandshakeTimeout, testPhase)
	}
	if tr.ResponseHeaderTimeout != testPhase {
		t.Errorf("ResponseHeaderTimeout = %v, want %v", tr.ResponseHeaderTimeout, testPhase)
	}
	if tr.ExpectContinueTimeout == 0 {
		t.Error("ExpectContinueTimeout unset: a server that never answers 100-Continue would stall the PUT")
	}
	if tr.IdleConnTimeout == 0 {
		t.Error("IdleConnTimeout unset")
	}
	if tr.DialContext == nil {
		t.Error("DialContext unset: the connect phase would fall back to no timeout")
	}

	d := newDialer(testPhase)
	if d.Timeout != testPhase {
		t.Errorf("dialer Timeout = %v, want %v", d.Timeout, testPhase)
	}
	if d.KeepAlive != testPhase {
		t.Errorf("dialer KeepAlive = %v, want %v: keepalive is the only thing watching a connection mid-transfer", d.KeepAlive, testPhase)
	}
}

// slowReadHandler stalls before draining the request body, so the socket
// buffers fill and the CLIENT's write blocks for at least stall. It then drains
// fast and answers immediately, leaving no silence after the write for
// ResponseHeaderTimeout to legitimately catch — the time under test is the
// transfer itself and nothing else.
//
// Note what this shape encodes: net/http starts the ResponseHeaderTimeout clock
// when the request write COMPLETES, so the guarantee is "a blocked write costs
// nothing", not "the server may take as long as it likes". A server that
// swallows the whole body into kernel buffers and then goes quiet is still on
// the clock, and should be.
func slowReadHandler(t *testing.T, stall time.Duration) http.HandlerFunc {
	t.Helper()
	return func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(stall)
		io.Copy(io.Discard, r.Body)
		w.WriteHeader(http.StatusOK)
	}
}

func TestSlowUploadIsNotChargedAgainstTheTimeout(t *testing.T) {
	srv := httptest.NewServer(slowReadHandler(t, testSlow))
	defer srv.Close()

	body := make([]byte, 8<<20) // past any loopback socket buffer, so the write really blocks
	c := &http.Client{Transport: newTransport(testPhase)}
	req, err := http.NewRequest(http.MethodPut, srv.URL+"/cli/beta/x.zip", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.ContentLength = int64(len(body))

	start := time.Now()
	resp, err := c.Do(req)
	if err != nil {
		t.Fatalf("PUT failed: %v — a slow upload must not count against a non-transfer timeout", err)
	}
	resp.Body.Close()
	if elapsed := time.Since(start); elapsed <= testPhase {
		t.Fatalf("upload took %v, not longer than the %v phase — the test proved nothing", elapsed, testPhase)
	}
}

func TestSlowDownloadIsNotChargedAgainstTheTimeout(t *testing.T) {
	// The Get direction: register fetch-dir reads whole artifacts back out.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK) // headers promptly...
		fl, ok := w.(http.Flusher)
		if !ok {
			t.Error("ResponseWriter is not a Flusher")
			return
		}
		fl.Flush()
		const chunks = 15
		for i := 0; i < chunks; i++ { // ...then trickle the body past the phase
			w.Write([]byte("payload"))
			fl.Flush()
			time.Sleep(testSlow / chunks)
		}
	}))
	defer srv.Close()

	c := &http.Client{Transport: newTransport(testPhase)}
	start := time.Now()
	resp, err := c.Get(srv.URL + "/cli/beta/x.zip")
	if err != nil {
		t.Fatalf("GET failed: %v", err)
	}
	got, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil {
		t.Fatalf("reading a slow body failed: %v — the download direction is being timed too", err)
	}
	if len(got) != 15*len("payload") {
		t.Errorf("short read: %d bytes", len(got))
	}
	if elapsed := time.Since(start); elapsed <= testPhase {
		t.Fatalf("download took %v, not longer than the %v phase — the test proved nothing", elapsed, testPhase)
	}
}

func TestSilenceBeforeResponseHeadersStillTimesOut(t *testing.T) {
	// The bound must still exist: a server that takes the request and then says
	// nothing is a stuck request, not a slow transfer.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		time.Sleep(testSlow)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	c := &http.Client{Transport: newTransport(testPhase)}
	req, err := http.NewRequest(http.MethodPut, srv.URL+"/k", bytes.NewReader([]byte("small")))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	start := time.Now()
	resp, err := c.Do(req)
	if err == nil {
		resp.Body.Close()
		t.Fatal("expected a timeout: a silent server after the request is written must not be waited on forever")
	}
	if elapsed := time.Since(start); elapsed >= testSlow {
		t.Errorf("gave up after %v, want about %v — ResponseHeaderTimeout is not being applied", elapsed, testPhase)
	}
}

// --- stall watchdog ----------------------------------------------------------
//
// The phase timeouts bound the parts of a request where no bytes SHOULD move.
// This bounds the part where bytes should be moving and are not: once headers
// are in, or once the request body has started going out, net/http bounds
// nothing, and a peer that holds the connection open while saying nothing would
// be waited on forever.

const testIdle = 200 * time.Millisecond

func TestStallGuardCancelsWhenNothingMoves(t *testing.T) {
	g := newStallGuard(context.Background(), testIdle)
	defer g.stop()

	select {
	case <-g.ctx.Done():
	case <-time.After(8 * testIdle):
		t.Fatal("guard never fired: a silent connection would be waited on forever")
	}
	if !g.fired.Load() {
		t.Error("guard cancelled without recording that IT was the cause")
	}
	err := g.annotate(g.ctx.Err())
	if !strings.Contains(err.Error(), "stalled: no bytes moved") {
		t.Errorf("annotate gave %q, want it to name the stall — a bare \"context canceled\" reads like the caller gave up", err)
	}
}

// trickle yields one byte every gap, total times, then EOF. It is the shape the
// watchdog must NOT kill: slow, but never silent.
type trickle struct {
	gap       time.Duration
	remaining int
}

func (tr *trickle) Read(b []byte) (int, error) {
	if tr.remaining == 0 {
		return 0, io.EOF
	}
	time.Sleep(tr.gap)
	tr.remaining--
	b[0] = 'x'
	return 1, nil
}

func TestStallGuardLeavesASlowButMovingTransferAlone(t *testing.T) {
	g := newStallGuard(context.Background(), testIdle)
	defer g.stop()

	// 12 reads a quarter of the budget apart: three times the idle window in
	// total, never a gap long enough to be a stall.
	src := &trickle{gap: testIdle / 4, remaining: 12}
	n, err := io.Copy(io.Discard, g.reader(src))
	if err != nil {
		t.Fatalf("copy: %v", err)
	}
	if n != 12 {
		t.Errorf("read %d bytes, want 12", n)
	}
	if g.fired.Load() {
		t.Error("guard killed a transfer that was moving — slow is not stalled, and a 16MB upload on a bad link is exactly this shape")
	}
	if g.ctx.Err() != nil {
		t.Errorf("context cancelled during a live transfer: %v", g.ctx.Err())
	}
}

// deadDoer accepts the request and then says nothing, like a peer holding a
// connection open. It never reads the body, so no progress is ever reported.
type deadDoer struct{}

func (deadDoer) Do(req *http.Request) (*http.Response, error) {
	<-req.Context().Done()
	return nil, req.Context().Err()
}

func TestStalledPutIsReportedAsStalled(t *testing.T) {
	c := New("acct", "downloads", "AKID", "SECRET", deadDoer{})
	c.idle = testIdle // the production budget is stallTimeout; this is the seam

	err := c.Put(context.Background(), "cli/beta/x.zip", []byte("payload"), "application/zip")
	if err == nil {
		t.Fatal("a silent peer must fail the PUT, not hang the cut")
	}
	if !strings.Contains(err.Error(), "stalled: no bytes moved") {
		t.Errorf("Put error %q does not say the transfer stalled", err)
	}
	if !strings.Contains(err.Error(), "cli/beta/x.zip") {
		t.Errorf("Put error %q does not name the object", err)
	}
}

func TestStalledGetIsReportedAsStalled(t *testing.T) {
	c := New("acct", "downloads", "AKID", "SECRET", deadDoer{})
	c.idle = testIdle

	_, err := c.Get(context.Background(), "cli/beta/x.zip")
	if err == nil {
		t.Fatal("a silent peer must fail the GET")
	}
	if !strings.Contains(err.Error(), "stalled: no bytes moved") {
		t.Errorf("Get error %q does not say the transfer stalled", err)
	}
}

func TestNewSetsTheProductionStallBudget(t *testing.T) {
	// The seam above must not be how the real client is configured.
	if got := New("acct", "downloads", "AKID", "SECRET", nil).idle; got != stallTimeout {
		t.Errorf("client idle = %v, want %v", got, stallTimeout)
	}
}

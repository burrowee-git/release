// Package r2 is a minimal stdlib AWS-SigV4 client for PUT/LIST/DELETE against a
// Cloudflare R2 bucket (S3-compatible API). Ported from the console's
// r2_mirror.go signer; no SDK dependency.
package r2

import (
	"bytes"
	"context"
	"encoding/xml"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type Doer interface {
	Do(*http.Request) (*http.Response, error)
}

type Client struct {
	endpoint    string // https://<account>.r2.cloudflarestorage.com
	bucket      string
	accessKeyID string
	secret      string
	doer        Doer
	idle        time.Duration // stall budget; a seam for tests, never configured
}

const (
	// phaseTimeout bounds each part of a request that moves no payload: the TCP
	// connect, the TLS handshake, and the wait for response headers once the
	// request has been written. It is also the TCP keepalive probe interval, so
	// a peer that dies mid-transfer is discovered rather than waited on.
	phaseTimeout = 30 * time.Second

	// expectContinueTimeout is Go's own default; named here only so nothing in
	// this transport is left to change underneath us.
	expectContinueTimeout = 1 * time.Second

	// idleConnTimeout is how long a pooled connection is kept for reuse. A cut
	// pushes seven objects back to back, so the second and later PUTs should
	// find the connection already open and TLS already done.
	idleConnTimeout = 90 * time.Second

	// stallTimeout is how long a transfer may move ZERO bytes before it is
	// abandoned. It is what the phase timeouts cannot see: once the response
	// headers are in, or once the request body has started going out, net/http
	// bounds nothing, so a peer that holds the connection open and says nothing
	// would be waited on forever. TCP keepalive eventually kills a peer that has
	// truly died; it says nothing about one that is alive and silent.
	stallTimeout = 30 * time.Second
)

// stallGuard abandons a transfer that stops moving. It is the counterpart to
// newTransport: that bounds the phases where no bytes SHOULD move, this bounds
// the phases where bytes should be moving and are not. Together they cover a
// request without ever asking how big it is.
//
// Progress is reported by the wrapped readers — the request body going out, the
// response body coming in — so "slow" and "stalled" stay distinguishable: a
// 16MB upload trickling at 40KB/s reports progress on every read and is left
// alone, while the same connection going quiet for stallTimeout is cancelled.
type stallGuard struct {
	ctx    context.Context
	cancel context.CancelFunc
	idle   time.Duration
	last   atomic.Int64 // UnixNano of the last byte moved
	fired  atomic.Bool
	done   chan struct{}
	once   sync.Once
}

func newStallGuard(parent context.Context, idle time.Duration) *stallGuard {
	ctx, cancel := context.WithCancel(parent)
	g := &stallGuard{ctx: ctx, cancel: cancel, idle: idle, done: make(chan struct{})}
	g.progress()
	go g.watch()
	return g
}

// progress marks the transfer as alive. Called by the wrapped readers, and once
// more when the response headers land, so the body read starts on a fresh clock
// rather than inheriting whatever the request write left behind.
func (g *stallGuard) progress() { g.last.Store(time.Now().UnixNano()) }

func (g *stallGuard) watch() {
	// Polling at a quarter of the budget keeps the worst-case overshoot to
	// 1.25x idle without a timer per read — reads are per 32KB and there are
	// hundreds of them in one upload.
	t := time.NewTicker(g.idle / 4)
	defer t.Stop()
	for {
		select {
		case <-g.done:
			return
		case <-g.ctx.Done():
			return
		case now := <-t.C:
			if now.Sub(time.Unix(0, g.last.Load())) >= g.idle {
				g.fired.Store(true)
				g.cancel()
				return
			}
		}
	}
}

// reader wraps r so every byte it yields counts as progress.
func (g *stallGuard) reader(r io.Reader) io.Reader { return &progressReader{r: r, g: g} }

// stop ends the watchdog and releases the context. Safe to call once per guard,
// which is what the deferred call at each use site does.
func (g *stallGuard) stop() {
	g.once.Do(func() { close(g.done) })
	g.cancel()
}

// annotate names what a cancelled context actually meant. Without it a stall
// surfaces as a bare "context canceled", which reads like the CALLER gave up —
// the single most misleading thing this error could say.
func (g *stallGuard) annotate(err error) error {
	if err != nil && g.fired.Load() {
		return fmt.Errorf("stalled: no bytes moved for %s: %w", g.idle, err)
	}
	return err
}

type progressReader struct {
	r io.Reader
	g *stallGuard
}

func (p *progressReader) Read(b []byte) (int, error) {
	n, err := p.r.Read(b)
	if n > 0 {
		p.g.progress()
	}
	return n, err
}

// newTransport builds the transport with every NON-TRANSFER phase bounded by
// phase, and the transfer itself bounded by nothing.
//
// A whole-request clock — http.Client.Timeout, or a deadline on the request
// context — cannot express that. It covers connect, TLS, body write AND
// response together, so it silently caps how large an object can be moved at
// all: under the flat 30s this package used to carry, a 15.9MB component zip
// needed 530KB/s or it could never finish, however healthy the link and the
// bucket were. On 2026-09-03 the cut machine's uplink fell to 39-90KB/s and
// three consecutive beta cuts died at publish-dir's first PUT. The link had
// changed, not the object, and `context deadline exceeded` said neither.
//
// The phases below are the ones where waiting really does mean something is
// wrong. ResponseHeaderTimeout is the load-bearing one: net/http starts its
// clock when the request write COMPLETES, so a body that takes minutes to push
// costs nothing and only the silence AFTER it is counted. Nothing here is
// charged for bytes in flight, in either direction, which is why one transport
// serves a 16MB Put and a 16MB Get with no size estimate anywhere.
//
// The precise guarantee is "a BLOCKED write costs nothing", not "the peer may
// take as long as it likes". A small body disappears into kernel buffers, so
// the write completes at once and a server that then goes quiet is on the clock
// — correctly. What has changed is that a 16MB upload over a slow link is
// flow-controlled, so its write does not complete until the bytes are actually
// gone, and the clock only starts there.
//
// What this deliberately does not bound: a connection that stays open while
// moving no bytes. TCP keepalive is the backstop — hence KeepAlive below — and
// a progress watchdog around the bodies would be the belt to that braces.
func newTransport(phase time.Duration) *http.Transport {
	return &http.Transport{
		DialContext:           newDialer(phase).DialContext,
		TLSHandshakeTimeout:   phase,
		ResponseHeaderTimeout: phase,
		ExpectContinueTimeout: expectContinueTimeout,
		IdleConnTimeout:       idleConnTimeout,
		ForceAttemptHTTP2:     true,
	}
}

// newDialer bounds the TCP connect, and sets the keepalive probe interval that
// is the only thing watching a connection once bytes are moving.
func newDialer(phase time.Duration) *net.Dialer {
	return &net.Dialer{Timeout: phase, KeepAlive: phase}
}

// newHTTPClient is the default Doer. It carries NO Timeout, on purpose: see
// newTransport.
func newHTTPClient() *http.Client {
	return &http.Client{Transport: newTransport(phaseTimeout)}
}

// New builds a Client. doer nil → newHTTPClient().
func New(accountID, bucket, accessKeyID, secret string, doer Doer) *Client {
	if doer == nil {
		doer = newHTTPClient()
	}
	return &Client{
		endpoint:    "https://" + accountID + ".r2.cloudflarestorage.com",
		bucket:      strings.Trim(bucket, "/"),
		accessKeyID: accessKeyID,
		secret:      secret,
		doer:        doer,
		idle:        stallTimeout,
	}
}

// Put uploads body to <endpoint>/<bucket>/<key> with a SigV4-signed PUT.
func (c *Client) Put(ctx context.Context, key string, body []byte, contentType string) error {
	g := newStallGuard(ctx, c.idle)
	defer g.stop()
	url := fmt.Sprintf("%s/%s/%s", c.endpoint, c.bucket, key)
	req, err := http.NewRequestWithContext(g.ctx, http.MethodPut, url, g.reader(bytes.NewReader(body)))
	if err != nil {
		return fmt.Errorf("r2: put: new request: %w", err)
	}
	req.Header.Set("Content-Type", contentType)
	// Set explicitly: the body is a wrapped reader now, so net/http cannot
	// measure it and would fall back to chunked encoding, which SigV4 signed
	// against the payload hash does not survive.
	req.ContentLength = int64(len(body))
	signV4(req, c.accessKeyID, c.secret, "auto", "s3", body, time.Now())
	resp, err := c.doer.Do(req)
	if err != nil {
		return fmt.Errorf("r2: put %s: %w", key, g.annotate(err))
	}
	defer resp.Body.Close()
	g.progress()
	if resp.StatusCode/100 != 2 {
		b, _ := io.ReadAll(io.LimitReader(g.reader(resp.Body), 512))
		return fmt.Errorf("r2: put %s: status %d: %s", key, resp.StatusCode, b)
	}
	return nil
}

// listResult is the subset of the S3 ListObjectsV2 XML response we read.
type listResult struct {
	Contents []struct {
		Key string `xml:"Key"`
	} `xml:"Contents"`
	IsTruncated bool   `xml:"IsTruncated"`
	NextToken   string `xml:"NextContinuationToken"`
}

// listPage performs one ListObjectsV2 request under its own stall guard and
// returns the response body and status.
func (c *Client) listPage(ctx context.Context, reqURL string) ([]byte, int, error) {
	g := newStallGuard(ctx, c.idle)
	defer g.stop()
	req, err := http.NewRequestWithContext(g.ctx, http.MethodGet, reqURL, nil)
	if err != nil {
		return nil, 0, fmt.Errorf("new request: %w", err)
	}
	signV4(req, c.accessKeyID, c.secret, "auto", "s3", nil, time.Now())
	resp, err := c.doer.Do(req)
	if err != nil {
		return nil, 0, g.annotate(err)
	}
	defer resp.Body.Close()
	g.progress()
	body, err := io.ReadAll(g.reader(resp.Body))
	if err != nil {
		return nil, resp.StatusCode, fmt.Errorf("read response: %w", g.annotate(err))
	}
	return body, resp.StatusCode, nil
}

// List returns every object key under prefix, following continuation tokens so
// buckets with more than 1000 objects are fully enumerated. An empty body is
// signed (GETs carry no payload).
func (c *Client) List(ctx context.Context, prefix string) ([]string, error) {
	var keys []string
	token := ""
	for {
		q := url.Values{}
		q.Set("list-type", "2")
		q.Set("prefix", prefix)
		if token != "" {
			q.Set("continuation-token", token)
		}
		// url.Values.Encode encodes spaces as '+', but SigV4 canonicalization
		// (signer.go signs req.URL.RawQuery verbatim) requires '%20'. Convert so
		// the signed query matches what S3/R2 re-encodes for verification — a
		// latent 403 once any value carries a space.
		enc := strings.ReplaceAll(q.Encode(), "+", "%20")
		reqURL := fmt.Sprintf("%s/%s?%s", c.endpoint, c.bucket, enc)
		// Per PAGE: each continuation is its own request, and a walk over
		// thousands of objects must not share one stall budget.
		body, status, err := c.listPage(ctx, reqURL)
		if err != nil {
			return nil, fmt.Errorf("r2: list %q: %w", prefix, err)
		}
		if status/100 != 2 {
			return nil, fmt.Errorf("r2: list %q: status %d: %s", prefix, status, body)
		}
		var lr listResult
		if err := xml.Unmarshal(body, &lr); err != nil {
			return nil, fmt.Errorf("r2: list %q: parse response: %w", prefix, err)
		}
		for _, o := range lr.Contents {
			keys = append(keys, o.Key)
		}
		if !lr.IsTruncated || lr.NextToken == "" {
			break
		}
		token = lr.NextToken
	}
	return keys, nil
}

// Get fetches one object's bytes. The counterpart of Put, added for the beta
// layout migration: reading an artifact back out is the only way to re-publish
// it under a different key without rebuilding it from source.
func (c *Client) Get(ctx context.Context, key string) ([]byte, error) {
	reqURL := fmt.Sprintf("%s/%s/%s", c.endpoint, c.bucket, key)
	g := newStallGuard(ctx, c.idle)
	defer g.stop()
	req, err := http.NewRequestWithContext(g.ctx, http.MethodGet, reqURL, nil)
	if err != nil {
		return nil, fmt.Errorf("r2: get %s: new request: %w", key, err)
	}
	signV4(req, c.accessKeyID, c.secret, "auto", "s3", nil, time.Now())
	resp, err := c.doer.Do(req)
	if err != nil {
		return nil, fmt.Errorf("r2: get %s: %w", key, g.annotate(err))
	}
	defer resp.Body.Close()
	g.progress() // the body read starts on a fresh clock, not the request's
	body, err := io.ReadAll(g.reader(resp.Body))
	if err != nil {
		return nil, fmt.Errorf("r2: get %s: read response: %w", key, g.annotate(err))
	}
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("r2: get %s: status %d: %s", key, resp.StatusCode, body)
	}
	return body, nil
}

// Delete removes the object at key. A 404/NoSuchKey is treated as success
// (deleting an absent key is a no-op, which keeps prune idempotent).
func (c *Client) Delete(ctx context.Context, key string) error {
	reqURL := fmt.Sprintf("%s/%s/%s", c.endpoint, c.bucket, key)
	g := newStallGuard(ctx, c.idle)
	defer g.stop()
	req, err := http.NewRequestWithContext(g.ctx, http.MethodDelete, reqURL, nil)
	if err != nil {
		return fmt.Errorf("r2: delete %s: new request: %w", key, err)
	}
	signV4(req, c.accessKeyID, c.secret, "auto", "s3", nil, time.Now())
	resp, err := c.doer.Do(req)
	if err != nil {
		return fmt.Errorf("r2: delete %s: %w", key, g.annotate(err))
	}
	defer resp.Body.Close()
	g.progress()
	if resp.StatusCode == http.StatusNotFound {
		return nil
	}
	if resp.StatusCode/100 != 2 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("r2: delete %s: status %d: %s", key, resp.StatusCode, b)
	}
	return nil
}

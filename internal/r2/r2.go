// Package r2 is a minimal stdlib AWS-SigV4 client for PUTting objects to a
// Cloudflare R2 bucket (S3-compatible API). Ported from the console's
// r2_mirror.go signer; no SDK dependency.
package r2

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

type Doer interface{ Do(*http.Request) (*http.Response, error) }

type Client struct {
	endpoint    string // https://<account>.r2.cloudflarestorage.com
	bucket      string
	accessKeyID string
	secret      string
	doer        Doer
}

// New builds a Client. doer nil → a 30s http.Client.
func New(accountID, bucket, accessKeyID, secret string, doer Doer) *Client {
	if doer == nil {
		doer = &http.Client{Timeout: 30 * time.Second}
	}
	return &Client{
		endpoint:    "https://" + accountID + ".r2.cloudflarestorage.com",
		bucket:      strings.Trim(bucket, "/"),
		accessKeyID: accessKeyID,
		secret:      secret,
		doer:        doer,
	}
}

// Put uploads body to <endpoint>/<bucket>/<key> with a SigV4-signed PUT.
func (c *Client) Put(ctx context.Context, key string, body []byte, contentType string) error {
	url := fmt.Sprintf("%s/%s/%s", c.endpoint, c.bucket, key)
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, url, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("r2: put: new request: %w", err)
	}
	req.Header.Set("Content-Type", contentType)
	req.ContentLength = int64(len(body))
	signV4(req, c.accessKeyID, c.secret, "auto", "s3", body, time.Now())
	resp, err := c.doer.Do(req)
	if err != nil {
		return fmt.Errorf("r2: put %s: %w", key, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("r2: put %s: status %d: %s", key, resp.StatusCode, b)
	}
	return nil
}

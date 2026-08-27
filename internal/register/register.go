package register

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"regexp"
	"time"
)

// httpTimeout bounds each console handshake call. Registration is best-effort
// (the caller logs and continues on error), but a hung/black-holed console must
// not stall the release cut indefinitely — a hang holds the decrypted signing
// key on disk longer than a clean failure would.
const httpTimeout = 30 * time.Second

// Register performs the nonce→sign→POST handshake against the console.
//
// If dryRun is true, the registration details are printed and no network
// calls are made.
//
// A 409 from the register endpoint is treated as success (already registered).
// Any other non-2xx status or transport error is returned as an error; the
// caller should log it as non-fatal.
func Register(cfg Config, payload []byte, dryRun bool) error {
	if dryRun {
		fmt.Printf("dry-run: client_id=%s\n", cfg.ClientID)
		fmt.Printf("dry-run: target=%s\n", cfg.ConsoleURL+"/api/v1/manage/releases")
		fmt.Printf("dry-run: payload=%s\n", string(payload))
		return nil
	}

	if cfg.ConsoleURL == "" {
		return fmt.Errorf("register: console_url not configured (set it in ~/.burrowee/release/config.toml or BURROWEE_CONSOLE_URL)")
	}

	// Refuse locally, before spending a nonce, when the payload's stamp shape
	// disagrees with the channel it claims to have cut on. The console
	// refuses too (release.StampMatchesChannel) — this is a client-side
	// fast-fail, not a substitute for it.
	if err := checkChannelStampShape(payload); err != nil {
		return err
	}

	// Step 1: fetch a nonce.
	nonceRaw, nonceB64, err := fetchNonce(cfg)
	if err != nil {
		return err
	}

	// Step 2: sign.
	sig := cfg.Sign(nonceRaw, payload)

	// Step 3: POST the registration.
	body := map[string]string{
		"client_id": cfg.ClientID,
		"nonce":     nonceB64,
		"payload":   base64.StdEncoding.EncodeToString(payload),
		"sig":       base64.StdEncoding.EncodeToString(sig),
	}
	bodyBytes, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("marshal register request: %w", err)
	}

	resp, err := postJSON(cfg.ConsoleURL+"/api/v1/manage/releases", bodyBytes)
	if err != nil {
		return fmt.Errorf("POST releases: %w", err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)

	switch resp.StatusCode {
	case http.StatusOK, http.StatusCreated:
		return nil
	case http.StatusConflict:
		log.Printf("already registered, ok")
		return nil
	default:
		return fmt.Errorf("register: unexpected status %d", resp.StatusCode)
	}
}

// stableStampPattern and betaStampPattern are %s-templated on the component
// name — spec §4.1's two exclusive-by-construction stamp shapes, the same
// ones the console's internal/console/release/channel.go anchors against
// (stableStampRe/betaStampRe there always match a "<comp>/" prefix once the
// version is joined to it, which is what this templates in directly).
const (
	stableStampPattern = `^%s/v[0-9]+\.[0-9]+\.[0-9]+\.[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9a-f]{8}$`
	betaStampPattern   = `^%s/v[0-9]+\.[0-9]+\.[0-9]+\.beta\.[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9a-f]{8}$`
)

// channelStampPayload is the subset of releaseRegisterRequest (console's
// internal/console/handlers/manage_releases.go) that checkChannelStampShape
// needs. Unknown fields in payload are ignored by json.Unmarshal.
type channelStampPayload struct {
	Component string `json:"component"`
	Version   string `json:"version"`
	// Channel empty means stable — an old client that predates the beta
	// channel never sends this field. Mirrors the console's default.
	Channel string `json:"channel"`
}

// checkChannelStampShape refuses locally when payload's stamp shape
// disagrees with the channel it claims to have cut on — see the call site in
// Register. Payload decode failures and unrecognized channel values are not
// refused here: fetchNonce/POST surfaces those the same as before this check
// existed, same as the console's own invalid_channel/bad_payload checks own
// them server-side.
func checkChannelStampShape(payload []byte) error {
	var req channelStampPayload
	if err := json.Unmarshal(payload, &req); err != nil {
		return nil
	}
	channel := req.Channel
	if channel == "" {
		channel = "stable"
	}
	var pattern string
	switch channel {
	case "stable":
		pattern = stableStampPattern
	case "beta":
		pattern = betaStampPattern
	default:
		return nil
	}
	re := regexp.MustCompile(fmt.Sprintf(pattern, regexp.QuoteMeta(req.Component)))
	full := req.Component + "/" + req.Version
	if !re.MatchString(full) {
		return fmt.Errorf("register: stamp %q is not a %s stamp", req.Version, channel)
	}
	return nil
}

// fetchNonce requests a single-use nonce from the console.
// Returns the raw (decoded) nonce bytes and the original base64 string.
func fetchNonce(cfg Config) (raw []byte, b64 string, err error) {
	reqBody, err := json.Marshal(map[string]string{"client_id": cfg.ClientID})
	if err != nil {
		return nil, "", fmt.Errorf("marshal nonce request: %w", err)
	}

	resp, err := postJSON(cfg.ConsoleURL+"/api/v1/manage/releases/nonce", reqBody)
	if err != nil {
		return nil, "", fmt.Errorf("POST releases/nonce: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		_, _ = io.Copy(io.Discard, resp.Body)
		return nil, "", fmt.Errorf("nonce: unexpected status %d", resp.StatusCode)
	}

	var out struct {
		Nonce     string `json:"nonce"`
		ExpiresAt int64  `json:"expires_at"`
	}
	if err = json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, "", fmt.Errorf("decode nonce response: %w", err)
	}

	raw, err = base64.StdEncoding.DecodeString(out.Nonce)
	if err != nil {
		return nil, "", fmt.Errorf("decode nonce base64: %w", err)
	}
	return raw, out.Nonce, nil
}

// postJSON POSTs body as application/json with a bounded timeout so a hung
// console cannot stall the release cut (see httpTimeout).
func postJSON(url string, body []byte) (*http.Response, error) {
	ctx, cancel := context.WithTimeout(context.Background(), httpTimeout)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		cancel()
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		cancel()
		return nil, err
	}
	// The caller closes resp.Body; cancel the context once it does so the
	// timeout's resources are released. http.Response has no hook, so wrap Body.
	resp.Body = &cancelBody{ReadCloser: resp.Body, cancel: cancel}
	return resp, nil
}

// cancelBody calls cancel after the response body is closed, releasing the
// request context's timer.
type cancelBody struct {
	io.ReadCloser
	cancel context.CancelFunc
}

func (b *cancelBody) Close() error {
	err := b.ReadCloser.Close()
	b.cancel()
	return err
}

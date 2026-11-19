package smtpd

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// spamVerdict is the MX-inline Rspamd result stored as cleartext metadata on
// sealed rows (docs/E2EE.md: Rspamd is self-hosted and fast, so it runs on the
// accept path; Rails then routes by this metadata without the raw MIME).
type spamVerdict struct {
	Score   float64
	Action  string
	Symbols []string
}

// rspamdClient mirrors the Rails RspamdClient POST /checkv2 call.
type rspamdClient struct {
	url  string
	http *http.Client
}

func newRspamdClient(url string) *rspamdClient {
	if url == "" {
		return nil
	}
	return &rspamdClient{url: url, http: &http.Client{Timeout: 10 * time.Second}}
}

// check scores raw RFC 5322 bytes. Errors are returned (not fatal): the caller
// treats a failed scan as "no verdict" — mail acceptance never depends on
// Rspamd being up.
func (c *rspamdClient) check(raw []byte, clientIP, from, rcpt string) (*spamVerdict, error) {
	req, err := http.NewRequest(http.MethodPost, c.url+"/checkv2", bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/octet-stream")
	if clientIP != "" {
		req.Header.Set("IP", clientIP)
	}
	if from != "" {
		req.Header.Set("From", from)
	}
	if rcpt != "" {
		req.Header.Set("Rcpt", rcpt)
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("rspamd status %d", resp.StatusCode)
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	var parsed struct {
		Score   float64                    `json:"score"`
		Action  string                     `json:"action"`
		Symbols map[string]json.RawMessage `json:"symbols"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return nil, fmt.Errorf("rspamd response: %w", err)
	}
	verdict := &spamVerdict{Score: parsed.Score, Action: parsed.Action}
	for name := range parsed.Symbols {
		verdict.Symbols = append(verdict.Symbols, name)
	}
	return verdict, nil
}

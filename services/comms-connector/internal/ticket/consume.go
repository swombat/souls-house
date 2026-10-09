package ticket

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"net/url"
	"strings"
	"time"

	"services/comms-connector/internal/ids"
)

// The consume call (spec §3 step 4):
//
//	POST <COMMS_CONSUME_URL>/internal/comms/tickets/<ticket_id>/consume
//	Content-Type: application/json
//	X-Comms-Signature: base64url(HMAC-SHA256(secret, "comms-consume-v1\n" || ticket_id || "\n" || body))
//	body: {"ticket": "<the X-Comms-Ticket header value>"}
//
// The read proceeds only on HTTP 200, Content-Type application/json, and a
// body that is exactly one JSON object {"allowed": true} (no other fields,
// nothing after it). Everything else is a refusal: timeout, connection
// error, redirect, any other status, a malformed or oversized body.

const (
	consumeDomain    = "comms-consume-v1\n"
	DefaultTimeout   = 3 * time.Second
	maxConsumeBody   = 1024
	SignatureHeader  = "X-Comms-Signature"
	ReasonConsume    = "consume_refused"
	ReasonConsumeErr = "consume_unavailable"
)

var ErrConsumeURL = errors.New("COMMS_CONSUME_URL missing or invalid")

// Consumer calls Rails' consume endpoint.
type Consumer struct {
	base   *url.URL
	secret Secret
	client *http.Client
}

// NewConsumer validates the base URL (http or https, no query, no fragment,
// no userinfo). The client ignores proxy environment variables and never
// follows redirects.
func NewConsumer(base string, s Secret, timeout time.Duration) (*Consumer, error) {
	u, err := url.Parse(base)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" ||
		u.RawQuery != "" || u.Fragment != "" || u.User != nil {
		return nil, ErrConsumeURL
	}
	if timeout <= 0 {
		timeout = DefaultTimeout
	}
	tr := &http.Transport{
		Proxy:                  nil,
		DisableCompression:     true,
		MaxResponseHeaderBytes: 8 << 10,
		ResponseHeaderTimeout:  timeout,
		IdleConnTimeout:        30 * time.Second,
	}
	return &Consumer{
		base:   u,
		secret: s,
		client: &http.Client{
			Transport: tr,
			Timeout:   timeout,
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
	}, nil
}

// ConsumeSignature is the request MAC Rails must verify.
func ConsumeSignature(s Secret, ticketID string, body []byte) string {
	return b64.EncodeToString(s.mac([]byte(consumeDomain+ticketID+"\n"), body))
}

// Consume returns nil only on an explicit allow. The returned error is a
// *Error with ReasonConsume (Rails said no, or answered anything but an
// explicit yes) or ReasonConsumeErr (transport failure or timeout).
func (c *Consumer) Consume(ctx context.Context, ticketID, header string) error {
	if !ids.ValidTicketID(ticketID) {
		return refuse(ReasonConsume)
	}
	body, err := json.Marshal(struct {
		Ticket string `json:"ticket"`
	}{header})
	if err != nil {
		return refuse(ReasonConsume)
	}
	u := *c.base
	u.Path = strings.TrimRight(u.Path, "/") + "/internal/comms/tickets/" + ticketID + "/consume"
	u.RawPath = ""
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u.String(), bytes.NewReader(body))
	if err != nil {
		return refuse(ReasonConsumeErr)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set(SignatureHeader, ConsumeSignature(c.secret, ticketID, body))
	resp, err := c.client.Do(req)
	if err != nil {
		return refuse(ReasonConsumeErr)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return refuse(ReasonConsume)
	}
	mt, _, err := mime.ParseMediaType(resp.Header.Get("Content-Type"))
	if err != nil || mt != "application/json" {
		return refuse(ReasonConsume)
	}
	rb, err := io.ReadAll(io.LimitReader(resp.Body, maxConsumeBody+1))
	if err != nil {
		return refuse(ReasonConsumeErr)
	}
	if len(rb) > maxConsumeBody {
		return refuse(ReasonConsume)
	}
	var ans struct {
		Allowed *bool `json:"allowed"`
	}
	dec := json.NewDecoder(bytes.NewReader(rb))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&ans); err != nil || ans.Allowed == nil || !*ans.Allowed {
		return refuse(ReasonConsume)
	}
	if _, err := dec.Token(); err != io.EOF {
		return refuse(ReasonConsume)
	}
	return nil
}

// Package rails posts signed events to
// POST /internal/comms/connections/:id/events (Internal::Comms::
// EventsController), signed with the connection's callback secret.
package rails

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"time"

	"services/comms-connector/internal/ids"
	"services/comms-connector/internal/sig"
)

// ErrConfig is returned for a base URL that is not a bare http(s) origin.
var ErrConfig = errors.New("COMMS_RAILS_URL must be an http(s) origin with no path")

// ErrTransport is any failure to get a reply. It never wraps the request.
var ErrTransport = errors.New("rails unreachable")

type Client struct {
	base *url.URL
	http *http.Client
	now  func() time.Time
}

// New takes the origin Rails is reachable at on the private network.
func New(origin string, hc *http.Client) (*Client, error) {
	u, err := url.Parse(origin)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" ||
		(u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.User != nil {
		return nil, ErrConfig
	}
	u.Path = ""
	if hc == nil {
		hc = &http.Client{Timeout: 30 * time.Second}
	}
	return &Client{base: u, http: hc, now: time.Now}, nil
}

// Reply is Rails' answer. CommittedSeq is set on a sequenced event's
// acknowledgement and on a sequence_gap refusal. Error is Rails' fixed
// refusal code ("bad_signature", "connection_not_accepting", …).
type Reply struct {
	Status       int
	CommittedSeq *int64
	Skipped      string
	Error        string
}

func EventsPath(ref string) string { return "/internal/comms/connections/" + ref + "/events" }

// Post sends one event body, signed for ref with secret.
func (c *Client) Post(ctx context.Context, ref string, secret []byte, body []byte) (Reply, error) {
	if !ids.ValidConnectionRef(ref) {
		return Reply{}, ErrConfig
	}
	path := EventsPath(ref)
	u := *c.base
	u.Path = path
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u.String(), bytes.NewReader(body))
	if err != nil {
		return Reply{}, ErrTransport
	}
	req.Header.Set("Content-Type", "application/json")
	if err := sig.SetEventHeaders(req.Header, secret, ref, http.MethodPost, path, body, c.now()); err != nil {
		return Reply{}, ErrTransport
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return Reply{}, ErrTransport
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	r := Reply{Status: resp.StatusCode}
	var parsed struct {
		CommittedSeq *int64 `json:"committed_seq"`
		Skipped      string `json:"skipped"`
		Error        string `json:"error"`
	}
	if len(raw) > 0 && json.Unmarshal(raw, &parsed) == nil {
		r.CommittedSeq, r.Skipped, r.Error = parsed.CommittedSeq, parsed.Skipped, parsed.Error
	}
	return r, nil
}

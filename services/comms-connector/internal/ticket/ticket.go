// Package ticket verifies the single-use read tickets minted by Rails
// (spec §3) and performs the consume call that re-validates them at release.
//
// Wire format of the X-Comms-Ticket header:
//
//	base64url(payload) "." base64url(HMAC-SHA256(secret, "comms-ticket-v1." || base64url(payload)))
//
// base64url is unpadded (RFC 4648 §5, no '='). payload is a JSON object with
// exactly the fields of Claims; unknown fields are refused.
//
// request_digest = lowercase hex SHA-256 of
//
//	METHOD "\n" PATH "\n" CANONICAL_QUERY
//
// where PATH is the escaped request path and CANONICAL_QUERY is the query
// parameters sorted by key, encoded as by Go's url.Values.Encode (empty
// string when there is no query). Repeated keys are refused before hashing.
package ticket

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"strings"
	"time"

	"services/comms-connector/internal/ids"
)

const (
	ticketDomain = "comms-ticket-v1."
	MaxHeaderLen = 4096
	MaxLifetime  = 60 * time.Second
	MinSecretLen = 32
)

// Reasons are fixed, content-free refusal codes. They go to the slog log as
// a reason field and never to the HTTP client.
const (
	ReasonMalformed = "ticket_malformed"
	ReasonSignature = "ticket_signature"
	ReasonExpired   = "ticket_expired"
	ReasonLifetime  = "ticket_lifetime"
	ReasonConn      = "ticket_connection"
	ReasonKeyGen    = "ticket_key_generation"
	ReasonDigest    = "ticket_digest"
)

// Error is a refusal with a fixed reason code.
type Error struct{ Reason string }

func (e *Error) Error() string { return "ticket refused: " + e.Reason }

func refuse(r string) error { return &Error{Reason: r} }

// Claims are the ticket fields.
type Claims struct {
	TicketID      string `json:"ticket_id"`
	ConnectionRef string `json:"connection_ref"`
	KeyGeneration uint64 `json:"key_generation"`
	AccessEpoch   uint64 `json:"access_epoch"`
	GrantID       string `json:"grant_id"`
	Principal     string `json:"principal"`
	APIKeyID      string `json:"api_key_id"`
	RunID         string `json:"run_id"`
	ExpiresAt     int64  `json:"expires_at"` // unix seconds
	RequestDigest string `json:"request_digest"`
}

// Secret holds COMMS_TICKET_SECRET. It never formats itself.
type Secret struct{ b []byte }

var ErrSecret = errors.New("COMMS_TICKET_SECRET missing or too short")

// NewSecret requires at least 32 bytes.
func NewSecret(s string) (Secret, error) {
	if len(s) < MinSecretLen {
		return Secret{}, ErrSecret
	}
	return Secret{b: []byte(s)}, nil
}

func (Secret) String() string   { return "[redacted]" }
func (Secret) GoString() string { return "[redacted]" }

func (s Secret) mac(parts ...[]byte) []byte {
	m := hmac.New(sha256.New, s.b)
	for _, p := range parts {
		m.Write(p)
	}
	return m.Sum(nil)
}

var b64 = base64.RawURLEncoding.Strict()

// Sign builds a header value. Rails does this in production; the connector
// uses it only in tests and in the README example.
func Sign(s Secret, c Claims) (string, error) {
	p, err := json.Marshal(c)
	if err != nil {
		return "", err
	}
	pb := b64.EncodeToString(p)
	return pb + "." + SignPayload(s, pb), nil
}

// SignPayload returns base64url(HMAC-SHA256(secret, "comms-ticket-v1." || payloadB64)).
func SignPayload(s Secret, payloadB64 string) string {
	return b64.EncodeToString(s.mac([]byte(ticketDomain + payloadB64)))
}

// CanonicalQuery sorts and encodes a raw query. ok is false for an
// unparseable query or a repeated key.
func CanonicalQuery(rawQuery string) (string, url.Values, bool) {
	v, err := url.ParseQuery(rawQuery)
	if err != nil {
		return "", nil, false
	}
	for _, vals := range v {
		if len(vals) != 1 {
			return "", nil, false
		}
	}
	return v.Encode(), v, true
}

// Digest computes request_digest.
func Digest(method, escapedPath, canonicalQuery string) string {
	h := sha256.Sum256([]byte(method + "\n" + escapedPath + "\n" + canonicalQuery))
	return hex.EncodeToString(h[:])
}

// Expect is what the request and the connector state require of a ticket.
type Expect struct {
	ConnectionRef string
	KeyGeneration uint64
	Digest        string
	Now           time.Time
}

// Verify checks, in order: shape, signature (constant time), fields,
// expiry and lifetime, connection_ref, key_generation and request digest.
// It does not consume; the caller must call Consumer.Consume next.
func Verify(s Secret, header string, want Expect) (Claims, error) {
	if header == "" || len(header) > MaxHeaderLen {
		return Claims{}, refuse(ReasonMalformed)
	}
	pb, sb, ok := strings.Cut(header, ".")
	if !ok || pb == "" || sb == "" || strings.Contains(sb, ".") {
		return Claims{}, refuse(ReasonMalformed)
	}
	sig, err := b64.DecodeString(sb)
	// The decoder skips '\r' and '\n'; requiring the canonical re-encoding
	// refuses those and any other non-canonical form.
	if err != nil || len(sig) != sha256.Size || b64.EncodeToString(sig) != sb {
		return Claims{}, refuse(ReasonMalformed)
	}
	if !hmac.Equal(sig, s.mac([]byte(ticketDomain+pb))) {
		return Claims{}, refuse(ReasonSignature)
	}
	raw, err := b64.DecodeString(pb)
	if err != nil || b64.EncodeToString(raw) != pb {
		return Claims{}, refuse(ReasonMalformed)
	}
	var c Claims
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&c); err != nil {
		return Claims{}, refuse(ReasonMalformed)
	}
	if _, err := dec.Token(); err != io.EOF {
		return Claims{}, refuse(ReasonMalformed)
	}
	if !ids.ValidTicketID(c.TicketID) || !ids.ValidConnectionRef(c.ConnectionRef) ||
		!ids.ValidOpaque(c.GrantID) || !ids.ValidOpaque(c.Principal) ||
		!ids.ValidOpaque(c.APIKeyID) || !ids.ValidOpaque(c.RunID) ||
		c.KeyGeneration == 0 || c.ExpiresAt <= 0 || len(c.RequestDigest) != 64 {
		return Claims{}, refuse(ReasonMalformed)
	}
	now := want.Now.Unix()
	if now >= c.ExpiresAt {
		return Claims{}, refuse(ReasonExpired)
	}
	if c.ExpiresAt-now > int64(MaxLifetime/time.Second) {
		return Claims{}, refuse(ReasonLifetime)
	}
	if subtle.ConstantTimeCompare([]byte(c.ConnectionRef), []byte(want.ConnectionRef)) != 1 {
		return Claims{}, refuse(ReasonConn)
	}
	if c.KeyGeneration != want.KeyGeneration {
		return Claims{}, refuse(ReasonKeyGen)
	}
	if subtle.ConstantTimeCompare([]byte(c.RequestDigest), []byte(want.Digest)) != 1 {
		return Claims{}, refuse(ReasonDigest)
	}
	return c, nil
}

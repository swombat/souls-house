// Package command verifies Rails → connector commands exactly as
// app/lib/comms_connector.rb sends them (CommsConnector.command): mutual TLS
// at the transport, then a COMMS_COMMAND_KEY signature over key id,
// connection, operation, command id, issue time and the body's SHA-256. The
// body repeats connection, operation, command id and issue time; they must
// agree with the URL and headers. A command older than MaxAge, issued before
// this process started, or with a command id already seen is refused.
package command

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strconv"
	"sync"
	"time"

	"services/comms-connector/internal/ids"
	"services/comms-connector/internal/sig"
)

// MaxAge matches CommsCommandSignature::MAX_AGE.
const MaxAge = 60 * time.Second

// Refused carries a fixed reason code, safe to log and to return.
type Refused struct{ Code string }

func (r *Refused) Error() string { return "command refused: " + r.Code }

func refuse(code string) error { return &Refused{Code: code} }

// Command is a verified command. CallbackSecret is only set by
// start_pairing; PhoneNumber, Attempt and PhoneRequest only by pair_phone.
type Command struct {
	Connection            string
	Operation             string
	CommandID             string
	IssuedAt              int64
	CallbackSecret        string
	CallbackSecretVersion int64
	PhoneNumber           string
	Attempt               int64
	// PhoneRequest is Rails' id for this one phone request (never the
	// number); the code or failure that answers it names it.
	PhoneRequest string
	// PhoneRequestSeq is that request's place in Rails' order (a positive
	// integer, increasing per connection): which of two requests is newer.
	PhoneRequestSeq int64
}

// String never shows the secret or the phone number.
func (c Command) String() string {
	return "command(" + c.Operation + " " + c.Connection + ")"
}

type body struct {
	Connection            *string         `json:"connection"`
	Operation             *string         `json:"operation"`
	CommandID             *string         `json:"command_id"`
	IssuedAt              *json.Number    `json:"issued_at"`
	CallbackSecret        *string         `json:"callback_secret"`
	CallbackSecretVersion *json.Number    `json:"callback_secret_version"`
	PhoneNumber           *string         `json:"phone_number"`
	PhoneRequest          *string         `json:"request_id"`
	PhoneRequestSeq       json.RawMessage `json:"request_seq"`
	// RawMessage, not json.Number: json.Number also takes "2" (a string),
	// and the attempt must be the integer Rails sends.
	Attempt json.RawMessage `json:"attempt"`
}

type Verifier struct {
	keyID     string
	key       []byte
	now       func() time.Time
	notBefore int64

	mu   sync.Mutex
	seen map[string]int64 // command id → issued at
}

// NewVerifier starts refusing anything issued before now: the seen-id cache
// is in memory, so a restart must not reopen the replay window.
func NewVerifier(keyID string, key []byte, now func() time.Time) *Verifier {
	if now == nil {
		now = time.Now
	}
	return &Verifier{keyID: keyID, key: key, now: now, notBefore: now().Unix(), seen: map[string]int64{}}
}

// Verify checks one request for connection ref and operation op (both from
// the URL path, validated by the caller).
func (v *Verifier) Verify(ref, op string, h http.Header, raw []byte) (Command, error) {
	keyID, commandID, issuedAt, signature := h.Get(sig.HeaderKeyID), h.Get(sig.HeaderCommandID), h.Get(sig.HeaderIssuedAt), h.Get(sig.HeaderCommand)
	if keyID == "" || commandID == "" || issuedAt == "" || signature == "" {
		return Command{}, refuse("missing_signature")
	}
	if keyID != v.keyID {
		return Command{}, refuse("unknown_key")
	}
	if !ids.ValidCommandID(commandID) {
		return Command{}, refuse("bad_command_id")
	}
	issued, err := strconv.ParseInt(issuedAt, 10, 64)
	if err != nil || issued <= 0 || len(issuedAt) > 12 || strconv.FormatInt(issued, 10) != issuedAt {
		return Command{}, refuse("bad_issued_at")
	}
	if !sig.VerifyCommand(v.key, signature, keyID, ref, op, commandID, issuedAt, raw) {
		return Command{}, refuse("bad_signature")
	}

	var b body
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&b); err != nil || dec.More() {
		return Command{}, refuse("bad_json")
	}
	if b.Connection == nil || *b.Connection != ref || b.Operation == nil || *b.Operation != op ||
		b.CommandID == nil || *b.CommandID != commandID || b.IssuedAt == nil || b.IssuedAt.String() != issuedAt {
		return Command{}, refuse("body_mismatch")
	}

	now := v.now().Unix()
	if now-issued > int64(MaxAge/time.Second) || issued-now > int64(MaxAge/time.Second) || issued < v.notBefore {
		return Command{}, refuse("stale_command")
	}

	cmd := Command{Connection: ref, Operation: op, CommandID: commandID, IssuedAt: issued}
	if b.CallbackSecret != nil {
		cmd.CallbackSecret = *b.CallbackSecret
	}
	if b.CallbackSecretVersion != nil {
		n, err := b.CallbackSecretVersion.Int64()
		if err != nil || n < 1 {
			return Command{}, refuse("bad_secret_version")
		}
		cmd.CallbackSecretVersion = n
	}
	if b.PhoneNumber != nil {
		cmd.PhoneNumber = *b.PhoneNumber
	}
	if b.PhoneRequest != nil {
		cmd.PhoneRequest = *b.PhoneRequest
	}
	if b.PhoneRequestSeq != nil {
		// A bare JSON integer, like the attempt.
		n, err := strconv.ParseInt(string(b.PhoneRequestSeq), 10, 64)
		if err != nil || n < 1 {
			return Command{}, refuse("bad_request_seq")
		}
		cmd.PhoneRequestSeq = n
	}
	if b.Attempt != nil {
		n, err := strconv.ParseInt(string(b.Attempt), 10, 64)
		if err != nil || n < 1 {
			return Command{}, refuse("bad_attempt")
		}
		cmd.Attempt = n
	}

	// Only a verified, fresh command reaches the cache, so it cannot be
	// flooded by forgeries.
	v.mu.Lock()
	defer v.mu.Unlock()
	for id, at := range v.seen {
		if now-at > 2*int64(MaxAge/time.Second) {
			delete(v.seen, id)
		}
	}
	if _, dup := v.seen[commandID]; dup {
		return Command{}, refuse("replayed_command")
	}
	v.seen[commandID] = issued
	return cmd, nil
}

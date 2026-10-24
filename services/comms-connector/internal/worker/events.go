package worker

import (
	"encoding/json"
	"time"

	"services/comms-connector/internal/provider"
)

// Rails' limits: CommsEvents::MAX_BATCH items per event, and CommsSignature::
// MAX_BODY_BYTES (1 MiB) per request. Batches are cut well inside both.
const (
	maxBatch      = 200
	maxEventBytes = 512 << 10
)

type chatEvent struct {
	Type  string          `json:"type"`
	Chats []provider.Chat `json:"chats"`
}

type messageEvent struct {
	Type     string             `json:"type"`
	Messages []provider.Message `json:"messages"`
}

type statusEvent struct {
	Type     string             `json:"type"`
	Status   string             `json:"status"`
	Identity *provider.Identity `json:"identity,omitempty"`
}

type qrEvent struct {
	Type      string `json:"type"`
	Code      string `json:"code"`
	IssuedAt  string `json:"issued_at"`
	ExpiresAt string `json:"expires_at"`
}

// Phone events name the phone request they answer (Rails' id for one ask;
// never the number), so Rails accepts only its latest request's result.
type phoneCodeEvent struct {
	Type      string `json:"type"`
	Code      string `json:"code"`
	IssuedAt  string `json:"issued_at"`
	ExpiresAt string `json:"expires_at"`
	RequestID string `json:"request_id"`
}

type phoneCodeFailedEvent struct {
	Type      string `json:"type"`
	Reason    string `json:"reason"`
	RequestID string `json:"request_id"`
}

func encodeQR(code string, issuedAt, expiresAt time.Time) ([]byte, error) {
	return encodeCode("pairing.qr", code, issuedAt, expiresAt)
}

// encodePhoneCode: the phone pairing code, shaped as a QR event.
func encodePhoneCode(code, request string, issuedAt, expiresAt time.Time) ([]byte, error) {
	return json.Marshal(phoneCodeEvent{Type: "pairing.phone_code", Code: code, RequestID: request,
		IssuedAt: wireTime(issuedAt), ExpiresAt: wireTime(expiresAt)})
}

func encodePhoneCodeFailed(reason, request string) ([]byte, error) {
	return json.Marshal(phoneCodeFailedEvent{Type: "pairing.phone_code_failed", Reason: reason, RequestID: request})
}

func encodeCode(typ, code string, issuedAt, expiresAt time.Time) ([]byte, error) {
	return json.Marshal(qrEvent{Type: typ, Code: code, IssuedAt: wireTime(issuedAt), ExpiresAt: wireTime(expiresAt)})
}

func wireTime(t time.Time) string {
	// Rails orders codes by issued_at ("an older code never replaces a
	// newer one") in a microsecond column, so whole seconds would make two
	// codes issued in the same second look like a replay.
	return t.UTC().Truncate(time.Microsecond).Format(time.RFC3339Nano)
}

func encodeStatus(status string, id *provider.Identity) ([]byte, error) {
	return json.Marshal(statusEvent{Type: "status.changed", Status: status, Identity: id})
}

// batches cuts items into events of at most maxBatch items and roughly
// maxEventBytes. A single item larger than that is truncated by the caller
// (see clampMessage) before it gets here.
func batches[T any](items []T, encode func([]T) ([]byte, error)) ([][]byte, error) {
	var out [][]byte
	for start := 0; start < len(items); {
		end := min(start+maxBatch, len(items))
		for {
			b, err := encode(items[start:end])
			if err != nil {
				return nil, err
			}
			if len(b) <= maxEventBytes || end-start == 1 {
				out = append(out, b)
				break
			}
			end = start + (end-start)/2
		}
		start = end
	}
	return out, nil
}

func encodeChats(chats []provider.Chat) ([][]byte, error) {
	return batches(chats, func(c []provider.Chat) ([]byte, error) { return json.Marshal(chatEvent{Type: "chat.upsert", Chats: c}) })
}

func encodeMessages(msgs []provider.Message) ([][]byte, error) {
	for i := range msgs {
		msgs[i] = clampMessage(msgs[i])
	}
	return batches(msgs, func(m []provider.Message) ([]byte, error) {
		return json.Marshal(messageEvent{Type: "message.upsert", Messages: m})
	})
}

// A message body or caption past 64 KiB is cut (at a rune boundary), so one
// message can never make an event Rails would refuse.
const maxText = 64 << 10

func clampMessage(m provider.Message) provider.Message {
	m.Body = clampText(m.Body)
	m.Caption = clampText(m.Caption)
	return m
}

func clampText(s *string) *string {
	if s == nil || len(*s) <= maxText {
		return s
	}
	cut := maxText
	for cut > 0 && (*s)[cut]&0xC0 == 0x80 {
		cut--
	}
	t := (*s)[:cut]
	return &t
}

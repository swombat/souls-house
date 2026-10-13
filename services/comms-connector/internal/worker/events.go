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

func encodeQR(code string, issuedAt, expiresAt time.Time) ([]byte, error) {
	// Rails orders codes by issued_at ("an older code never replaces a
	// newer one") in a microsecond column, so whole seconds would make two
	// codes issued in the same second look like a replay.
	return json.Marshal(qrEvent{Type: "pairing.qr", Code: code,
		IssuedAt:  issuedAt.UTC().Truncate(time.Microsecond).Format(time.RFC3339Nano),
		ExpiresAt: expiresAt.UTC().Truncate(time.Microsecond).Format(time.RFC3339Nano)})
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

// Package provider is the seam between a connection's worker and the
// messaging network. A Session is one linked device; it reports what
// happens to a Sink, which turns it into signed events for Rails.
//
// Two implementations: Synthetic (here, deterministic, for tests and the
// log smoke test) and whatsmeow (package whatsapp).
package provider

import (
	"context"
	"errors"
	"time"

	"services/comms-connector/internal/store"
)

var (
	// ErrNotPaired: the session has no linked device and was not asked to pair.
	ErrNotPaired = errors.New("session is not paired")
	// ErrLoggedOut: the phone removed this linked device. The sink has been told.
	ErrLoggedOut = errors.New("session was logged out")
	// ErrNotPairing: a phone pairing code was asked for while the session
	// is not pairing (already linked, or its pairing has ended).
	ErrNotPairing = errors.New("session is not pairing")
)

// Phone pairing failures, as Rails shows them (CommsEvents::PHONE_CODE_FAILURES).
// Fixed words: never the number, never WhatsApp's own error text.
const (
	PhoneCodeInvalid     = "phone_invalid"
	PhoneCodeRateLimited = "rate_limited"
	PhoneCodeNotReady    = "not_ready"
	PhoneCodeExpired     = "expired"
	PhoneCodeFailed      = "failed"
)

// Identity is who the paired account is, as Rails shows it on the connection.
type Identity struct {
	UserID      string `json:"user_id,omitempty"`
	DisplayName string `json:"display_name,omitempty"`
}

// Chat is one conversation. Field names are Rails' (CommsEvents::CHAT_FIELDS).
type Chat struct {
	ProviderChatID string     `json:"provider_chat_id"`
	Name           string     `json:"name,omitempty"`
	Kind           string     `json:"kind,omitempty"`
	LastActivityAt *time.Time `json:"last_activity_at,omitempty"`
}

// Message is one received message (CommsEvents::MESSAGE_FIELDS). Media are
// never downloaded: MediaKind names it and Caption carries any caption.
type Message struct {
	ProviderMessageID string    `json:"provider_message_id"`
	Chat              string    `json:"chat"`
	SenderID          string    `json:"sender_id,omitempty"`
	SenderName        string    `json:"sender_name,omitempty"`
	SentAt            time.Time `json:"sent_at"`
	Body              *string   `json:"body"`
	MediaKind         *string   `json:"media_kind"`
	Caption           *string   `json:"caption"`
}

// Sink receives what a session produces. QR codes go to Rails at once and
// are never stored; everything else is queued durably, in order.
type Sink interface {
	QR(ctx context.Context, code string, issuedAt, expiresAt time.Time) error
	// PhoneCode is the 8-character code the owner types into WhatsApp
	// ("Link with phone number instead"). Like a QR: posted at once, never
	// stored or logged.
	PhoneCode(ctx context.Context, code string, issuedAt, expiresAt time.Time) error
	// PhoneCodeFailed: asking for a phone code failed, or the pairing it
	// belonged to ended unused. reason is one of the PhoneCode* words.
	PhoneCodeFailed(ctx context.Context, reason string) error
	Connected(ctx context.Context, id Identity) error
	LoggedOut(ctx context.Context) error
	Chats(ctx context.Context, chats []Chat) error
	Messages(ctx context.Context, msgs []Message) error
}

// Session is one connection's linked device.
type Session interface {
	// Run connects and reports to sink until ctx ends (returning ctx.Err()),
	// the phone logs the device out (ErrLoggedOut), or, when the session is
	// not paired and pair is false, at once with ErrNotPaired. With pair
	// true and no device, it pairs first, reporting QR codes.
	Run(ctx context.Context, sink Sink, pair bool) error
	// Logout removes the linked device at the network side, if there is
	// one. Called only while Run is not running. Best effort: the caller
	// deletes the store either way.
	Logout(ctx context.Context) error
}

// PhonePairer is a Session that can pair by phone number instead of a QR
// (whatsmeow's PairPhone). RequestPhoneCode may be called while Run is
// pairing; it waits until the pairing connection is up (the first QR), asks
// for a code for phone (E.164 digits, no "+") and reports the code, or the
// failure, to sink. ErrNotPairing (reported to nobody) when the session is
// not pairing.
type PhonePairer interface {
	RequestPhoneCode(ctx context.Context, sink Sink, phone string) error
}

// Factory makes a session over a connection's encrypted store.
type Factory func(st *store.Store) (Session, error)

// Package provider defines the message source seam. Slice 1 has exactly one
// implementation, Synthetic; whatsmeow arrives in slice 4 behind the same
// interface.
package provider

import (
	"context"
	"fmt"
	"time"
)

// Chat is one conversation. ID is a connector-assigned opaque ID, never a JID.
type Chat struct {
	ID        string
	Name      string
	UpdatedAt time.Time
}

// Message is one received message. Media is never downloaded in milestone 1.
type Message struct {
	ID         string
	ChatID     string
	ChatName   string
	SenderName string
	Body       string
	SentAt     time.Time
}

// Sink receives what a provider produces. The encrypted store implements it.
type Sink interface {
	PutChat(ctx context.Context, c Chat) error
	PutMessage(ctx context.Context, m Message) error
}

// Provider feeds a Sink until it is done or ctx is cancelled.
type Provider interface {
	Run(ctx context.Context, sink Sink) error
}

// Synthetic emits a deterministic set of fake chats and messages. The same
// configuration always produces the same IDs, names, bodies and timestamps,
// so re-running it against an existing store is idempotent.
type Synthetic struct {
	Chats           int
	MessagesPerChat int
	// Marker is embedded in every chat name, sender name and body. Tests set
	// it to a CANARY-COMMS-… string; production leaves it empty.
	Marker string
	// Base is the timestamp of the first message.
	Base time.Time
}

// DefaultSynthetic is what the binary runs with -provider synthetic.
func DefaultSynthetic() Synthetic {
	return Synthetic{
		Chats:           3,
		MessagesPerChat: 20,
		Base:            time.Date(2026, 1, 1, 9, 0, 0, 0, time.UTC),
	}
}

// ChatID returns the deterministic ID of chat i.
func ChatID(i int) string { return fmt.Sprintf("chat-%04d", i) }

// Events returns everything Run would emit, in order, without a sink.
func (s Synthetic) Events() ([]Chat, []Message) {
	var chats []Chat
	var msgs []Message
	for c := 0; c < s.Chats; c++ {
		chat := Chat{
			ID:   ChatID(c),
			Name: fmt.Sprintf("Synthetic chat %d %s", c, s.Marker),
		}
		last := s.Base.UTC()
		for m := 0; m < s.MessagesPerChat; m++ {
			at := s.Base.Add(time.Duration(c)*time.Hour + time.Duration(m)*time.Minute).UTC()
			last = at
			msgs = append(msgs, Message{
				ID:         fmt.Sprintf("%s-msg-%05d", chat.ID, m),
				ChatID:     chat.ID,
				ChatName:   chat.Name,
				SenderName: fmt.Sprintf("Synthetic sender %d %s", m%3, s.Marker),
				Body:       fmt.Sprintf("Synthetic message %d in chat %d %s", m, c, s.Marker),
				SentAt:     at,
			})
		}
		chat.UpdatedAt = last
		chats = append(chats, chat)
	}
	return chats, msgs
}

// Run emits all chats, then all messages, and returns.
func (s Synthetic) Run(ctx context.Context, sink Sink) error {
	chats, msgs := s.Events()
	return Inject(ctx, sink, chats, msgs)
}

// Inject writes the given chats and messages straight into a sink. It is the
// test injection path. The binary never exposes it over the network.
func Inject(ctx context.Context, sink Sink, chats []Chat, msgs []Message) error {
	for _, c := range chats {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := sink.PutChat(ctx, c); err != nil {
			return err
		}
	}
	for _, m := range msgs {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := sink.PutMessage(ctx, m); err != nil {
			return err
		}
	}
	return nil
}

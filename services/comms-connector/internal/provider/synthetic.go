package provider

import (
	"context"
	"fmt"
	"sync/atomic"
	"time"

	"services/comms-connector/internal/store"
)

// Synthetic is a deterministic stand-in for WhatsApp. Pairing pushes
// QRCodes codes QRInterval apart and then succeeds; once paired (recorded in
// the store, so it survives a restart) every Run reports Connected and the
// same chats and messages. The same configuration always produces the same
// ids and content, so a replay is a no-op in Rails.
type Synthetic struct {
	QRCodes         int
	QRInterval      time.Duration
	QRLifetime      time.Duration
	Chats           int
	MessagesPerChat int
	// Marker is embedded in every name and body. Tests set a canary.
	Marker string
	Base   time.Time
	// LogoutSignal, when closed, makes a running session behave as if the
	// phone removed the device.
	LogoutSignal <-chan struct{}

	logouts atomic.Int32
}

func DefaultSynthetic() *Synthetic {
	return &Synthetic{
		QRCodes: 2, QRInterval: 200 * time.Millisecond, QRLifetime: 20 * time.Second,
		Chats: 3, MessagesPerChat: 5,
		Base: time.Date(2026, 10, 1, 9, 0, 0, 0, time.UTC),
	}
}

// Factory returns a provider.Factory sharing this configuration.
func (s *Synthetic) Factory() Factory {
	return func(st *store.Store) (Session, error) { return &syntheticSession{cfg: s, st: st}, nil }
}

// Logouts counts Logout calls on paired sessions (for tests).
func (s *Synthetic) Logouts() int { return int(s.logouts.Load()) }

// Events returns the chats and messages a paired session reports.
func (s *Synthetic) Events() ([]Chat, []Message) {
	var chats []Chat
	var msgs []Message
	for c := 0; c < s.Chats; c++ {
		chatID := fmt.Sprintf("4477009%05d@s.whatsapp.net", c)
		var last time.Time
		for m := 0; m < s.MessagesPerChat; m++ {
			at := s.Base.Add(time.Duration(c)*time.Hour + time.Duration(m)*time.Minute).UTC()
			last = at
			body := fmt.Sprintf("Synthetic message %d in chat %d %s", m, c, s.Marker)
			msg := Message{
				ProviderMessageID: fmt.Sprintf("SYN%02d%05d", c, m),
				Chat:              chatID,
				SenderID:          chatID,
				SenderName:        fmt.Sprintf("Synthetic sender %d %s", c, s.Marker),
				SentAt:            at,
				Body:              &body,
			}
			if m == 1 { // one media message per chat: kind and caption, no body
				kind, caption := "image", fmt.Sprintf("Synthetic caption %s", s.Marker)
				msg.Body, msg.MediaKind, msg.Caption = nil, &kind, &caption
			}
			msgs = append(msgs, msg)
		}
		lastCopy := last
		chats = append(chats, Chat{ProviderChatID: chatID, Name: fmt.Sprintf("Synthetic chat %d %s", c, s.Marker), Kind: "direct", LastActivityAt: &lastCopy})
	}
	return chats, msgs
}

type syntheticSession struct {
	cfg *Synthetic
	st  *store.Store
}

const syntheticPaired = "synthetic_paired"

func (s *syntheticSession) paired(ctx context.Context) (bool, error) {
	v, ok, err := s.st.Meta(ctx, syntheticPaired)
	return ok && v == "1", err
}

func (s *syntheticSession) Run(ctx context.Context, sink Sink, pair bool) error {
	paired, err := s.paired(ctx)
	if err != nil {
		return err
	}
	if !paired {
		if !pair {
			return ErrNotPaired
		}
		for i := 0; i < s.cfg.QRCodes; i++ {
			now := time.Now().UTC()
			// Rails orders codes by issued_at at second precision.
			if err := sink.QR(ctx, fmt.Sprintf("2@synthetic-%d-%s", i, s.cfg.Marker), now, now.Add(s.cfg.QRLifetime)); err != nil {
				return err
			}
			if err := sleep(ctx, s.cfg.QRInterval); err != nil {
				return err
			}
		}
		if err := s.st.SetMeta(ctx, map[string]string{syntheticPaired: "1"}); err != nil {
			return err
		}
	}
	if err := sink.Connected(ctx, Identity{UserID: "447700900000", DisplayName: "Synthetic " + s.cfg.Marker}); err != nil {
		return err
	}
	chats, msgs := s.cfg.Events()
	if err := sink.Chats(ctx, chats); err != nil {
		return err
	}
	if err := sink.Messages(ctx, msgs); err != nil {
		return err
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-s.cfg.LogoutSignal:
		if err := s.st.SetMeta(context.WithoutCancel(ctx), map[string]string{syntheticPaired: "0"}); err != nil {
			return err
		}
		if err := sink.LoggedOut(ctx); err != nil {
			return err
		}
		return ErrLoggedOut
	}
}

func (s *syntheticSession) Logout(ctx context.Context) error {
	if paired, err := s.paired(ctx); err != nil || !paired {
		return err
	}
	s.cfg.logouts.Add(1)
	return s.st.SetMeta(ctx, map[string]string{syntheticPaired: "0"})
}

func sleep(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

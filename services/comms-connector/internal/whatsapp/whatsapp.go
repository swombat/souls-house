// Package whatsapp is the whatsmeow provider: one linked device per
// connection, its session tables (whatsmeow_*) living in the connection's
// SQLCipher store through sqlstore.NewWithDB on our own *sql.DB.
//
// Receive only. There is no send code here, and nothing calls whatsmeow's
// send, presence or read-receipt functions.
//
// Hygiene (proposal 2026-10-09 §3): whatsmeow gets waLog.Noop (its Debug
// logger logs every node, phone numbers included), and libsignal's default
// stdout logger is replaced by a no-op at init.
package whatsapp

import (
	"context"
	"errors"
	"sync"
	"time"

	signallogger "go.mau.fi/libsignal/logger"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	wastore "go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"

	"services/comms-connector/internal/provider"
	"services/comms-connector/internal/store"
)

// Dialect is what whatsmeow's dbutil is told the *sql.DB speaks.
const Dialect = "sqlite3"

var (
	ErrPairingEnded = errors.New("pairing ended without success")
	errStore        = errors.New("whatsmeow store failed")
)

func init() {
	var quiet signallogger.Loggable = noopSignalLogger{}
	signallogger.Setup(&quiet)
	// The name the phone shows under Linked devices.
	wastore.SetOSInfo("souls.house", [3]uint32{1, 0, 0})
}

type noopSignalLogger struct{}

func (noopSignalLogger) Debug(string, string)   {}
func (noopSignalLogger) Info(string, string)    {}
func (noopSignalLogger) Warning(string, string) {}
func (noopSignalLogger) Error(string, string)   {}
func (noopSignalLogger) Configure(string)       {}

// Factory makes whatsmeow sessions over each connection's store.
func Factory() provider.Factory {
	return func(st *store.Store) (provider.Session, error) {
		return newSession(sqlstore.NewWithDB(st.DB(), Dialect, waLog.Noop)), nil
	}
}

type Session struct {
	container *sqlstore.Container

	// Phone pairing (RequestPhoneCode). ready closes with the first QR,
	// when the pairing connection is up; ended closes when pairing is over,
	// linked or not.
	ready, ended       chan struct{}
	readyOnce, endOnce sync.Once
	requests           sync.Mutex // one phone code request at a time

	mu        sync.Mutex
	pairPhone func(ctx context.Context, phone string) (string, error)
	firstQR   time.Time
	// codeSink is the sink of the request whose code was issued last: when
	// pairing ends unused, that request is told its code expired.
	codeSink provider.Sink
}

func newSession(c *sqlstore.Container) *Session {
	return &Session{container: c, ready: make(chan struct{}), ended: make(chan struct{})}
}

func (s *Session) endPairing() { s.endOnce.Do(func() { close(s.ended) }) }

func (s *Session) device(ctx context.Context) (*wastore.Device, error) {
	if err := s.container.Upgrade(ctx); err != nil {
		return nil, errStore
	}
	dev, err := s.container.GetFirstDevice(ctx)
	if err != nil {
		return nil, errStore
	}
	return dev, nil
}

func (s *Session) Run(ctx context.Context, sink provider.Sink, pair bool) error {
	defer s.endPairing()
	dev, err := s.device(ctx)
	if err != nil {
		return err
	}
	if dev.ID == nil && !pair {
		return provider.ErrNotPaired
	}
	cli := whatsmeow.NewClient(dev, waLog.Noop)
	// A message is acknowledged to WhatsApp only once every handler has
	// returned, i.e. once it is in the durable outbox.
	cli.SynchronousAck = true

	h := &handler{cli: cli, sink: sink, ctx: ctx, loggedOut: make(chan struct{}), names: map[types.JID]bool{}}
	cli.AddEventHandlerWithSuccessStatus(h.handle)
	defer cli.Disconnect()

	if dev.ID == nil {
		qr, err := cli.GetQRChannel(ctx)
		if err != nil {
			return err
		}
		s.mu.Lock()
		s.pairPhone = func(ctx context.Context, phone string) (string, error) {
			// The phone shows "Chrome (Linux)" while the code is entered;
			// once linked it shows the name SetOSInfo gave. WhatsApp
			// accepts only common "Browser (OS)" names here.
			return cli.PairPhone(ctx, phone, true, whatsmeow.PairClientChrome, "Chrome (Linux)")
		}
		s.mu.Unlock()
		if err := cli.ConnectContext(ctx); err != nil {
			return err
		}
		if err := s.pairLoop(ctx, qr, sink); err != nil {
			return err
		}
		s.endPairing()
	} else if err := cli.ConnectContext(ctx); err != nil {
		return err
	}

	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-h.loggedOut:
		if err := sink.LoggedOut(ctx); err != nil {
			return err
		}
		return provider.ErrLoggedOut
	}
}

// pairLoop pushes each code with its expiry until the phone scans one or a
// phone code is entered (both end in QRChannelSuccess). If the codes run
// out after a phone code was issued, Rails is told that code has expired,
// through the sink of the request that got it.
func (s *Session) pairLoop(ctx context.Context, qr <-chan whatsmeow.QRChannelItem, sink provider.Sink) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case item, ok := <-qr:
			if !ok {
				return s.pairingEnded(ctx, sink)
			}
			switch item.Event {
			case whatsmeow.QRChannelEventCode:
				now := time.Now()
				if err := sink.QR(ctx, item.Code, now, now.Add(item.Timeout)); err != nil {
					return err
				}
				s.markReady(now)
			case whatsmeow.QRChannelSuccess.Event:
				return nil
			default:
				// timeout, client outdated, scanned without multidevice, error
				return s.pairingEnded(ctx, sink)
			}
		}
	}
}

// markReady: the pairing connection is up; PairPhone may now be called.
func (s *Session) markReady(at time.Time) {
	s.readyOnce.Do(func() {
		s.mu.Lock()
		s.firstQR = at
		s.mu.Unlock()
		close(s.ready)
	})
}

func (s *Session) pairingEnded(ctx context.Context, sink provider.Sink) error {
	s.endPairing()
	s.mu.Lock()
	issued := s.codeSink
	s.mu.Unlock()
	if issued != nil {
		// Best effort: the code also carries its own expiry. Through the
		// request's own sink, so the expiry names that request.
		_ = issued.PhoneCodeFailed(ctx, provider.PhoneCodeExpired)
	}
	return ErrPairingEnded
}

// PairingWindow: whatsmeow's pairing socket closes when its QR codes run
// out (60 s, then 20 s each; six codes in practice), and a phone code dies
// with it. A code is reported to expire at the end of that window.
const PairingWindow = 160 * time.Second

// ReadyTimeout bounds the wait for the pairing connection (the first QR).
var ReadyTimeout = 30 * time.Second

// RequestPhoneCode asks WhatsApp for an 8-character code the owner enters
// on the phone under Linked devices → Link with phone number instead.
// whatsmeow requires a live pairing connection that has already produced
// its first QR, so this waits for that. The number and the code are never
// logged, and WhatsApp's error text (which can echo the number) is reduced
// to a fixed word.
func (s *Session) RequestPhoneCode(ctx context.Context, sink provider.Sink, phone string) error {
	s.requests.Lock()
	defer s.requests.Unlock()
	timer := time.NewTimer(ReadyTimeout)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-s.ended:
		return provider.ErrNotPairing
	case <-timer.C:
		return sink.PhoneCodeFailed(ctx, provider.PhoneCodeNotReady)
	case <-s.ready:
	}
	select {
	case <-s.ended:
		return provider.ErrNotPairing
	default:
	}
	s.mu.Lock()
	pairPhone, first := s.pairPhone, s.firstQR
	s.mu.Unlock()
	if pairPhone == nil {
		return provider.ErrNotPairing
	}
	code, err := pairPhone(ctx, phone)
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return sink.PhoneCodeFailed(ctx, phoneFailure(err))
	}
	now := time.Now()
	expires := first.Add(PairingWindow)
	if expires.Before(now.Add(10 * time.Second)) {
		expires = now.Add(10 * time.Second)
	}
	s.mu.Lock()
	s.codeSink = sink
	s.mu.Unlock()
	return sink.PhoneCode(ctx, code, now, expires)
}

func phoneFailure(err error) string {
	switch {
	case errors.Is(err, whatsmeow.ErrPhoneNumberTooShort), errors.Is(err, whatsmeow.ErrPhoneNumberIsNotInternational),
		errors.Is(err, whatsmeow.ErrIQBadRequest):
		return provider.PhoneCodeInvalid
	case errors.Is(err, whatsmeow.ErrIQRateOverLimit):
		return provider.PhoneCodeRateLimited
	default:
		return provider.PhoneCodeFailed
	}
}

// Logout removes this linked device at WhatsApp (remove-companion-device),
// which needs a live connection, then whatsmeow deletes its keys. If
// WhatsApp cannot be reached the local keys are deleted anyway; the caller
// deletes the whole store after.
func (s *Session) Logout(ctx context.Context) error {
	dev, err := s.device(ctx)
	if err != nil {
		return err
	}
	if dev.ID == nil {
		return nil
	}
	cli := whatsmeow.NewClient(dev, waLog.Noop)
	cli.EnableAutoReconnect = false
	connected := make(chan struct{})
	var once sync.Once
	cli.AddEventHandler(func(evt any) {
		if _, ok := evt.(*events.Connected); ok {
			once.Do(func() { close(connected) })
		}
	})
	defer cli.Disconnect()
	if err := cli.ConnectContext(ctx); err == nil {
		select {
		case <-connected:
			if err := cli.Logout(ctx); err == nil {
				return nil
			}
		case <-ctx.Done():
		}
	}
	_ = dev.Delete(context.WithoutCancel(ctx))
	return errors.New("logout did not reach WhatsApp; local keys deleted")
}

// handler turns whatsmeow events into sink calls. It returns false (no
// ack) when the sink could not store an event durably.
type handler struct {
	cli       *whatsmeow.Client
	sink      provider.Sink
	ctx       context.Context
	loggedOut chan struct{}
	once      sync.Once

	mu    sync.Mutex
	names map[types.JID]bool // chats already named this run
}

func (h *handler) handle(evt any) bool {
	ctx := h.ctx
	switch e := evt.(type) {
	case *events.Connected:
		id := provider.Identity{}
		if jid := h.cli.Store.ID; jid != nil {
			id.UserID = jid.User
		}
		id.DisplayName = h.cli.Store.PushName
		return h.sink.Connected(ctx, id) == nil
	case *events.LoggedOut:
		h.once.Do(func() { close(h.loggedOut) })
		return true
	case *events.Message:
		m, ok := h.convert(ctx, e)
		if !ok {
			return true
		}
		if chat, named := h.chatFor(ctx, e.Info.Chat, ""); named {
			if h.sink.Chats(ctx, []provider.Chat{chat}) != nil {
				return false
			}
		}
		return h.sink.Messages(ctx, []provider.Message{m}) == nil
	case *events.HistorySync:
		return h.history(ctx, e) == nil
	}
	return true
}

func (h *handler) history(ctx context.Context, e *events.HistorySync) error {
	if e.Data == nil {
		return nil
	}
	for _, conv := range e.Data.GetConversations() {
		jid, err := types.ParseJID(conv.GetID())
		if err != nil || skipChat(jid) {
			continue
		}
		jid = h.canonical(ctx, jid)
		var msgs []provider.Message
		var last time.Time
		for _, hm := range conv.GetMessages() {
			evt, err := h.cli.ParseWebMessage(jid, hm.GetMessage())
			if err != nil {
				continue
			}
			if m, ok := h.convert(ctx, evt); ok {
				msgs = append(msgs, m)
				if m.SentAt.After(last) {
					last = m.SentAt
				}
			}
		}
		chat, _ := h.chatFor(ctx, jid, conv.GetName())
		if !last.IsZero() {
			chat.LastActivityAt = &last
		}
		if err := h.sink.Chats(ctx, []provider.Chat{chat}); err != nil {
			return err
		}
		if err := h.sink.Messages(ctx, msgs); err != nil {
			return err
		}
	}
	return nil
}

// skipChat drops status updates (contacts' stories, not conversations).
func skipChat(jid types.JID) bool {
	return jid == types.StatusBroadcastJID || jid.IsEmpty()
}

// canonical maps a LID (hidden user id) to the phone-number JID when
// whatsmeow knows it, so one person is one chat.
func (h *handler) canonical(ctx context.Context, jid types.JID) types.JID {
	if jid.Server != types.HiddenUserServer {
		return jid.ToNonAD()
	}
	if pn, err := h.cli.Store.LIDs.GetPNForLID(ctx, jid.ToNonAD()); err == nil && !pn.IsEmpty() {
		return pn.ToNonAD()
	}
	return jid.ToNonAD()
}

func kindOf(jid types.JID) string {
	switch jid.Server {
	case types.GroupServer:
		return "group"
	case types.BroadcastServer:
		return "broadcast"
	case types.NewsletterServer:
		return "channel"
	default:
		return "direct"
	}
}

// chatFor names a chat: the history sync's name, else a contact's name for
// a direct chat, else the group subject (one lookup per chat per run).
// named is false when the chat was already named this run.
func (h *handler) chatFor(ctx context.Context, jid types.JID, name string) (provider.Chat, bool) {
	jid = h.canonical(ctx, jid)
	chat := provider.Chat{ProviderChatID: jid.String(), Kind: kindOf(jid), Name: name}
	h.mu.Lock()
	seen := h.names[jid]
	h.names[jid] = true
	h.mu.Unlock()
	if seen && name == "" {
		return chat, false
	}
	if chat.Name == "" {
		switch chat.Kind {
		case "direct":
			if c, err := h.cli.Store.Contacts.GetContact(ctx, jid); err == nil && c.Found {
				chat.Name = firstNonEmpty(c.FullName, c.FirstName, c.BusinessName, c.PushName)
			}
		case "group":
			lctx, cancel := context.WithTimeout(ctx, 10*time.Second)
			if info, err := h.cli.GetGroupInfo(lctx, jid); err == nil && info != nil {
				chat.Name = info.Name
			}
			cancel()
		}
	}
	return chat, true
}

func firstNonEmpty(s ...string) string {
	for _, v := range s {
		if v != "" {
			return v
		}
	}
	return ""
}

// convert keeps text and media markers; protocol messages, reactions,
// edits, polls' votes and status updates are not modelled in milestone 1.
func (h *handler) convert(ctx context.Context, e *events.Message) (provider.Message, bool) {
	if e == nil || e.Message == nil || e.IsEdit || skipChat(e.Info.Chat) {
		return provider.Message{}, false
	}
	body, kind, caption, ok := content(e.Message)
	if !ok {
		return provider.Message{}, false
	}
	chat := h.canonical(ctx, e.Info.Chat)
	sender := h.canonical(ctx, e.Info.Sender)
	name := e.Info.PushName
	if e.Info.IsFromMe {
		name = h.cli.Store.PushName
	}
	return provider.Message{
		ProviderMessageID: e.Info.ID,
		Chat:              chat.String(),
		SenderID:          sender.String(),
		SenderName:        name,
		SentAt:            e.Info.Timestamp.UTC(),
		Body:              body,
		MediaKind:         kind,
		Caption:           caption,
	}, true
}

func str(s string) *string { return &s }

func nonEmpty(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func content(m *waE2E.Message) (body, kind, caption *string, ok bool) {
	switch {
	case m.GetConversation() != "":
		return str(m.GetConversation()), nil, nil, true
	case m.GetExtendedTextMessage() != nil:
		return str(m.GetExtendedTextMessage().GetText()), nil, nil, true
	case m.GetImageMessage() != nil:
		return nil, str("image"), nonEmpty(m.GetImageMessage().GetCaption()), true
	case m.GetVideoMessage() != nil:
		k := "video"
		if m.GetVideoMessage().GetGifPlayback() {
			k = "gif"
		}
		return nil, str(k), nonEmpty(m.GetVideoMessage().GetCaption()), true
	case m.GetPtvMessage() != nil:
		return nil, str("video_note"), nil, true
	case m.GetAudioMessage() != nil:
		if m.GetAudioMessage().GetPTT() {
			return nil, str("voice_note"), nil, true
		}
		return nil, str("audio"), nil, true
	case m.GetDocumentMessage() != nil:
		return nil, str("document"), nonEmpty(m.GetDocumentMessage().GetCaption()), true
	case m.GetStickerMessage() != nil:
		return nil, str("sticker"), nil, true
	case m.GetLocationMessage() != nil, m.GetLiveLocationMessage() != nil:
		return nil, str("location"), nil, true
	case m.GetContactMessage() != nil, m.GetContactsArrayMessage() != nil:
		return nil, str("contact"), nil, true
	case m.GetPollCreationMessage() != nil, m.GetPollCreationMessageV3() != nil:
		q := m.GetPollCreationMessage().GetName()
		if q == "" {
			q = m.GetPollCreationMessageV3().GetName()
		}
		return nil, str("poll"), nonEmpty(q), true
	}
	return nil, nil, nil, false
}

package whatsapp

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	signallogger "go.mau.fi/libsignal/logger"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waAdv"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"go.mau.fi/whatsmeow/util/keys"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"

	"services/comms-connector/internal/provider"
	"services/comms-connector/internal/store"
)

const canary = "CANARY-COMMS-wa-5d1e"

func openStore(t *testing.T, path string, key []byte) *store.Store {
	t.Helper()
	st, err := store.Open(context.Background(), path, key)
	if err != nil {
		t.Fatal(err)
	}
	return st
}

func newKey() []byte { k := make([]byte, 32); rand.Read(k); return k }

var (
	ownJID  = types.NewJID("447700900001", types.DefaultUserServer)
	peerJID = types.NewJID("447700900002", types.DefaultUserServer)
	peerLID = types.NewJID("123456789012345", types.HiddenUserServer)
	grpJID  = types.NewJID("120363000000000001", types.GroupServer)
)

// fakePaired writes a device as pairing would, without WhatsApp.
func fakePaired(t *testing.T, st *store.Store) {
	t.Helper()
	ctx := context.Background()
	s := mustSession(t, st)
	dev, err := s.device(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var priv [32]byte
	rand.Read(priv[:])
	dev.NoiseKey = keys.NewKeyPairFromPrivateKey(priv)
	rand.Read(priv[:])
	dev.IdentityKey = keys.NewKeyPairFromPrivateKey(priv)
	dev.SignedPreKey = dev.IdentityKey.CreateSignedPreKey(1)
	dev.AdvSecretKey = bytes.Repeat([]byte{1}, 32)
	dev.ID = &ownJID
	dev.Account = &waAdv.ADVSignedDeviceIdentity{
		Details: []byte("account-details"), AccountSignature: bytes.Repeat([]byte{2}, 64),
		AccountSignatureKey: bytes.Repeat([]byte{3}, 32), DeviceSignature: bytes.Repeat([]byte{4}, 64),
	}
	dev.PushName = "Owner " + canary
	if err := dev.Save(ctx); err != nil {
		t.Fatal(err)
	}
	if _, _, err := dev.Contacts.PutPushName(ctx, peerJID, "Alice "+canary); err != nil {
		t.Fatal(err)
	}
	if err := dev.LIDs.PutLIDMapping(ctx, peerLID, peerJID); err != nil {
		t.Fatal(err)
	}
}

func mustSession(t *testing.T, st *store.Store) *Session {
	s, err := Factory()(st)
	if err != nil {
		t.Fatal(err)
	}
	return s.(*Session)
}

// whatsmeow's own tables live in our SQLCipher store (NewWithDB on our
// *sql.DB), and a paired device survives closing and reopening the store:
// a restart does not need a re-pair.
func TestSessionStoreLivesInTheEncryptedStoreAndSurvivesReopen(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "store.db")
	key := newKey()
	st := openStore(t, path, key)
	fakePaired(t, st)
	st.Close()

	st2 := openStore(t, path, key)
	defer st2.Close()
	dev, err := mustSession(t, st2).device(ctx)
	if err != nil || dev.ID == nil || dev.ID.User != ownJID.User {
		t.Fatalf("device lost on reopen: %v", err)
	}
	var n int
	if err := st2.DB().QueryRow(`SELECT count(*) FROM sqlite_master WHERE name LIKE 'whatsmeow_%'`).Scan(&n); err != nil || n < 10 {
		t.Fatalf("whatsmeow tables: %d %v", n, err)
	}
	// Nothing readable on disk: not the JIDs, names or the SQLite header.
	raw, _ := os.ReadFile(path)
	for _, needle := range []string{canary, ownJID.User, peerJID.User, "SQLite format 3", "whatsmeow_device"} {
		if bytes.Contains(raw, []byte(needle)) {
			t.Errorf("store file contains %q in plaintext", needle)
		}
	}
	// And the wrong key opens nothing.
	if _, err := store.Open(ctx, path, newKey()); !errors.Is(err, store.ErrOpen) {
		t.Fatal("store opened with another key")
	}
}

type recSink struct {
	msgs  []provider.Message
	chats []provider.Chat

	mu          sync.Mutex
	qrs         []string
	phoneCodes  []phoneCodeCall
	phoneFailed []string
}

type phoneCodeCall struct {
	code              string
	issued, expiresAt time.Time
}

func (r *recSink) QR(_ context.Context, code string, _, _ time.Time) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.qrs = append(r.qrs, code)
	return nil
}
func (r *recSink) PhoneCode(_ context.Context, code string, issued, expires time.Time) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.phoneCodes = append(r.phoneCodes, phoneCodeCall{code, issued, expires})
	return nil
}
func (r *recSink) PhoneCodeFailed(_ context.Context, reason string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.phoneFailed = append(r.phoneFailed, reason)
	return nil
}
func (r *recSink) Connected(context.Context, provider.Identity) error { return nil }
func (r *recSink) LoggedOut(context.Context) error                    { return nil }
func (r *recSink) Chats(_ context.Context, c []provider.Chat) error {
	r.chats = append(r.chats, c...)
	return nil
}
func (r *recSink) Messages(_ context.Context, m []provider.Message) error {
	r.msgs = append(r.msgs, m...)
	return nil
}

// An unpaired session is never started on boot: only start_pairing pairs.
func TestUnpairedSessionDoesNotConnectUnlessPairing(t *testing.T) {
	st := openStore(t, filepath.Join(t.TempDir(), "store.db"), newKey())
	defer st.Close()
	err := mustSession(t, st).Run(context.Background(), &recSink{}, false)
	if !errors.Is(err, provider.ErrNotPaired) {
		t.Fatalf("got %v", err)
	}
	if err := mustSession(t, st).Logout(context.Background()); err != nil {
		t.Fatalf("logout of an unpaired store: %v", err)
	}
}

func TestMessageConversion(t *testing.T) {
	st := openStore(t, filepath.Join(t.TempDir(), "store.db"), newKey())
	defer st.Close()
	fakePaired(t, st)
	dev, _ := mustSession(t, st).device(context.Background())
	sink := &recSink{}
	h := &handler{cli: whatsmeow.NewClient(dev, waLog.Noop), sink: sink, ctx: context.Background(), names: map[types.JID]bool{}}

	at := time.Date(2026, 10, 12, 9, 30, 0, 0, time.UTC)
	msg := func(id string, chat, sender types.JID, m *waE2E.Message) *events.Message {
		return &events.Message{Info: types.MessageInfo{ID: id, Timestamp: at, PushName: "Alice",
			MessageSource: types.MessageSource{Chat: chat, Sender: sender}}, Message: m}
	}
	for _, e := range []*events.Message{
		msg("T1", peerJID, peerJID, &waE2E.Message{Conversation: proto.String("hello " + canary)}),
		msg("T2", peerLID, peerLID, &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{Text: proto.String("via lid")}}),
		msg("I1", peerJID, peerJID, &waE2E.Message{ImageMessage: &waE2E.ImageMessage{Caption: proto.String("a caption")}}),
		msg("V1", grpJID, peerJID, &waE2E.Message{AudioMessage: &waE2E.AudioMessage{PTT: proto.Bool(true)}}),
		msg("S1", types.StatusBroadcastJID, peerJID, &waE2E.Message{Conversation: proto.String("a story")}),
		msg("R1", peerJID, peerJID, &waE2E.Message{ReactionMessage: &waE2E.ReactionMessage{Text: proto.String("👍")}}),
		msg("P1", peerJID, peerJID, &waE2E.Message{ProtocolMessage: &waE2E.ProtocolMessage{}}),
	} {
		if !h.handle(e) {
			t.Fatalf("%s not acknowledged", e.Info.ID)
		}
	}
	edit := msg("E1", peerJID, peerJID, &waE2E.Message{Conversation: proto.String("edited")})
	edit.IsEdit = true
	h.handle(edit)

	got := map[string]provider.Message{}
	for _, m := range sink.msgs {
		got[m.ProviderMessageID] = m
	}
	if len(got) != 4 {
		t.Fatalf("kept %d messages, want T1 T2 I1 V1: %v", len(got), got)
	}
	if t1 := got["T1"]; *t1.Body != "hello "+canary || t1.Chat != "447700900002@s.whatsapp.net" || t1.SenderName != "Alice" || !t1.SentAt.Equal(at) || t1.MediaKind != nil {
		t.Errorf("T1 %+v", t1)
	}
	if t2 := got["T2"]; t2.Chat != peerJID.String() || t2.SenderID != peerJID.String() {
		t.Errorf("a LID chat was not mapped to the phone number: %+v", t2)
	}
	if i1 := got["I1"]; i1.Body != nil || *i1.MediaKind != "image" || *i1.Caption != "a caption" {
		t.Errorf("I1 %+v", i1)
	}
	if v1 := got["V1"]; *v1.MediaKind != "voice_note" || v1.Chat != grpJID.String() {
		t.Errorf("V1 %+v", v1)
	}
	// One chat upsert per chat, the direct chat named from contacts.
	var direct *provider.Chat
	for i, c := range sink.chats {
		if c.ProviderChatID == peerJID.String() {
			if direct != nil {
				t.Error("direct chat named twice in one run")
			}
			direct = &sink.chats[i]
		}
	}
	if direct == nil || direct.Kind != "direct" || !strings.HasPrefix(direct.Name, "Alice") {
		t.Errorf("direct chat %+v", direct)
	}
}

func TestLibsignalLoggerIsSilenced(t *testing.T) {
	if _, ok := signallogger.Logger.(noopSignalLogger); !ok {
		t.Fatalf("libsignal logs through %T", signallogger.Logger)
	}
}

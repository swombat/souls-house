// wa-sqlcipher-probe: drive whatsmeow's real store/sqlstore over a SQLCipher
// driver with SYNTHETIC data only. No network, no pairing, no phone numbers.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime/debug"
	"sort"
	"strings"
	"time"

	"go.mau.fi/whatsmeow/proto/waAdv"
	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waHistorySync"
	"go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/util/keys"
	"google.golang.org/protobuf/proto"
)

const driverName = "sqlite3-sqlcipher"

// Synthetic key material: derived from a fixed seed so the searcher can
// recompute every needle without a plaintext needle file.
func seedBytes(field string) [32]byte { return sha256.Sum256([]byte("wa-probe-seed|" + field)) }

func dbKeyHex() string { k := seedBytes("sqlcipher-db-key"); return hex.EncodeToString(k[:]) }

// Non-JID-shaped synthetic users: these are not phone numbers.
var (
	ownJID  = types.JID{User: "canaryown", Server: types.DefaultUserServer, Device: 7}
	ownLID  = types.JID{User: "canaryownlid", Server: types.HiddenUserServer, Device: 7}
	peerJID = types.JID{User: "canarypeer", Server: types.DefaultUserServer}
	peerLID = types.JID{User: "canarypeerlid", Server: types.HiddenUserServer}
	grpJID  = types.JID{User: "canarygroup", Server: types.GroupServer}
)

func c(field string) string { return "CANARY-WA-" + field }

func must(err error, what string) {
	if err != nil {
		fmt.Fprintf(os.Stderr, "FAIL %s: %v\n", what, err)
		os.Exit(1)
	}
}

func openContainer(ctx context.Context, dataDir string, extra []string) *sqlstore.Container {
	registerCipherDriver(driverName, dbKeyHex(), extra)
	dsn := "file:" + filepath.Join(dataDir, "comms.db") + dsnSuffix()
	// The unmodified public constructor: sql.Open(dialect, address) + Upgrade.
	container, err := sqlstore.New(ctx, driverName, dsn, nil)
	must(err, "sqlstore.New")
	return container
}

var defaultPragmas = []string{
	"PRAGMA foreign_keys = ON",
	"PRAGMA journal_mode = WAL",
	"PRAGMA temp_store = MEMORY",
	"PRAGMA busy_timeout = 5000",
}

func main() {
	mode := flag.String("mode", "", "write | loop | dump | badkey")
	dataDir := flag.String("data", "", "data dir")
	flag.Parse()
	debug.SetTraceback("none")
	ctx := context.Background()
	fmt.Fprintln(os.Stderr, "driver:", driverLabel)
	switch *mode {
	case "write":
		doWrite(ctx, *dataDir)
	case "loop":
		doLoop(ctx, *dataDir)
	case "dump":
		doDump(ctx, *dataDir)
	case "export":
		// Positive control only: write a PLAINTEXT copy to prove the scanner
		// finds needles when they really are on disk.
		registerCipherDriver(driverName, dbKeyHex(), nil)
		db := rawDB(*dataDir)
		db.SetMaxOpenConns(1)
		_, err := db.Exec(`ATTACH DATABASE ? AS plaintext KEY ''`, flag.Arg(0))
		must(err, "attach")
		db.SetMaxOpenConns(1)
		rows, err := db.Query(`SELECT name FROM main.sqlite_master WHERE type='table'`)
		must(err, "tables")
		var ts []string
		for rows.Next() {
			var t string
			must(rows.Scan(&t), "scan")
			ts = append(ts, t)
		}
		rows.Close()
		for _, t := range ts {
			_, err = db.Exec(fmt.Sprintf(`CREATE TABLE plaintext."%s" AS SELECT * FROM main."%s"`, t, t))
			must(err, "copy "+t)
		}
		fmt.Fprintln(os.Stderr, "exported plaintext control to", flag.Arg(0))
	case "badkey":
		doBadKey(*dataDir)
	default:
		fmt.Fprintln(os.Stderr, "unknown mode")
		os.Exit(2)
	}
}

func doWrite(ctx context.Context, dataDir string) {
	container := openContainer(ctx, dataDir, defaultPragmas)
	defer container.Close()
	db := rawDB(dataDir)
	defer db.Close()
	var jm, ts, cv string
	must(db.QueryRow("PRAGMA journal_mode").Scan(&jm), "journal_mode")
	must(db.QueryRow("PRAGMA temp_store").Scan(&ts), "temp_store")
	must(db.QueryRow(cipherVersionSQL).Scan(&cv), "cipher_version")
	var sv string
	must(db.QueryRow("SELECT sqlite_version()").Scan(&sv), "sqlite_version")
	fmt.Printf("journal_mode=%s temp_store=%s cipher_version=%q sqlite_version=%s\n", jm, ts, cv, sv)

	dev := container.NewDevice()
	dev.NoiseKey = keys.NewKeyPairFromPrivateKey(seedBytes("noise-priv"))
	dev.IdentityKey = keys.NewKeyPairFromPrivateKey(seedBytes("identity-priv"))
	dev.SignedPreKey = dev.IdentityKey.CreateSignedPreKey(1)
	adv := seedBytes("adv-secret")
	dev.AdvSecretKey = adv[:]
	dev.ID = &ownJID
	dev.LID = ownLID
	dev.Platform = c("platform")
	dev.PushName = c("own-pushname")
	dev.BusinessName = c("own-businessname")
	dev.CompanionMetaNonce = c("companion-meta-nonce")
	sigKey := seedBytes("account-signature-key")
	dev.Account = &waAdv.ADVSignedDeviceIdentity{
		Details:             []byte(c("account-details") + "-padding-to-make-it-longer"),
		AccountSignature:    bytes.Repeat([]byte("CANARY-WA-acctsig-"), 4)[:64],
		AccountSignatureKey: sigKey[:],
		DeviceSignature:     bytes.Repeat([]byte("CANARY-WA-devsig-"), 4)[:64],
	}
	must(dev.Save(ctx), "device.Save (PutDevice)")
	fmt.Println("device saved:", dev.ID)

	idk := seedBytes("peer-identity")
	must(dev.Identities.PutIdentity(ctx, peerJID.SignalAddress().String(), idk), "PutIdentity")
	must(dev.Sessions.PutSession(ctx, peerJID.SignalAddress().String(), []byte(c("session-record")+"-"+hexOf(seedBytes("session-bytes")))), "PutSession")
	must(dev.Sessions.PutManySessions(ctx, map[string][]byte{
		peerLID.SignalAddress().String(): []byte(c("session-many-1")),
	}), "PutManySessions")
	pk, err := dev.PreKeys.GenOnePreKey(ctx)
	must(err, "GenOnePreKey")
	pks, err := dev.PreKeys.GetOrGenPreKeys(ctx, 5)
	must(err, "GetOrGenPreKeys")
	must(dev.PreKeys.MarkPreKeysAsUploaded(ctx, pks[len(pks)-1].KeyID), "MarkPreKeysAsUploaded")
	n, err := dev.PreKeys.UploadedPreKeyCount(ctx)
	must(err, "UploadedPreKeyCount")
	fmt.Printf("prekeys: one=%d batch=%d uploaded=%d (random keys, generated inside whatsmeow)\n", pk.KeyID, len(pks), n)
	must(dev.SenderKeys.PutSenderKey(ctx, grpJID.String(), peerJID.SignalAddress().String(), []byte(c("sender-key")+"-"+hexOf(seedBytes("sender-key-bytes")))), "PutSenderKey")
	ask := seedBytes("app-state-sync-key")
	must(dev.AppStateKeys.PutAppStateSyncKey(ctx, []byte(c("appstate-keyid")), store.AppStateSyncKey{Data: ask[:], Fingerprint: []byte(c("appstate-fingerprint")), Timestamp: 1}), "PutAppStateSyncKey")
	var hash [128]byte
	copy(hash[:], c("appstate-hash"))
	must(dev.AppState.PutAppStateVersion(ctx, "regular", 3, hash), "PutAppStateVersion")
	must(dev.AppState.PutAppStateMutationMACs(ctx, "regular", 3, []store.AppStateMutationMAC{{IndexMAC: pad32(c("index-mac")), ValueMAC: pad32(c("value-mac"))}}), "PutAppStateMutationMACs")
	_, _, err = dev.Contacts.PutPushName(ctx, peerJID, c("peer-pushname"))
	must(err, "PutPushName")
	_, _, err = dev.Contacts.PutBusinessName(ctx, peerJID, c("peer-businessname"))
	must(err, "PutBusinessName")
	must(dev.Contacts.PutContactName(ctx, peerJID, c("peer-fullname"), c("peer-firstname")), "PutContactName")
	must(dev.Contacts.PutAllContactNames(ctx, []store.ContactEntry{{JID: peerLID, FirstName: c("bulk-firstname"), FullName: c("bulk-fullname")}}), "PutAllContactNames")
	must(dev.Contacts.PutManyRedactedPhones(ctx, []store.RedactedPhoneEntry{{JID: peerLID, RedactedPhone: c("redacted-phone")}}), "PutManyRedactedPhones")
	must(dev.ChatSettings.PutMutedUntil(ctx, peerJID, time.Unix(2000000000, 0)), "PutMutedUntil")
	must(dev.ChatSettings.PutPinned(ctx, peerJID, true), "PutPinned")
	must(dev.ChatSettings.PutWASARootSecretID(ctx, peerJID, c("wasa-root-secret-id")), "PutWASARootSecretID")
	ms := seedBytes("message-secret")
	must(dev.MsgSecrets.PutMessageSecret(ctx, peerJID, peerJID, c("msgid-1"), ms[:]), "PutMessageSecret")
	ms2 := seedBytes("message-secret-history")
	must(dev.MsgSecrets.PutMessageSecrets(ctx, []store.MessageSecretInsert{{Chat: grpJID, Sender: peerJID, ID: c("msgid-hist"), Secret: ms2[:]}}), "PutMessageSecrets")
	pt := seedBytes("privacy-token")
	must(dev.PrivacyTokens.PutPrivacyTokens(ctx, store.PrivacyToken{User: peerJID, Token: pt[:], Timestamp: time.Now(), SenderTimestamp: time.Now()}), "PutPrivacyTokens")
	salt := seedBytes("nct-salt")
	must(dev.NCTSalt.PutNCTSalt(ctx, salt[:]), "PutNCTSalt")
	// The decryption event buffer stores DECRYPTED message plaintext inside the store.
	plain, _ := proto.Marshal(&waE2E.Message{Conversation: proto.String(c("decrypted-plaintext-in-event-buffer"))})
	must(dev.EventBuffer.DoDecryptionTxn(ctx, func(ctx context.Context) error {
		return dev.EventBuffer.PutBufferedEvent(ctx, seedBytes("ciphertext-hash"), plain, time.Now())
	}), "PutBufferedEvent")
	out, _ := proto.Marshal(&waE2E.Message{Conversation: proto.String(c("outgoing-plaintext-retry-buffer"))})
	must(dev.EventBuffer.AddOutgoingEvent(ctx, peerJID, c("out-msgid"), "message", out), "AddOutgoingEvent")
	must(dev.LIDs.PutLIDMapping(ctx, peerLID, peerJID), "PutLIDMapping")
	must(dev.LIDs.PutManyLIDMappings(ctx, []store.LIDMapping{{LID: types.JID{User: "canaryhistlid", Server: types.HiddenUserServer}, PN: types.JID{User: "canaryhistpn", Server: types.DefaultUserServer}}}), "PutManyLIDMappings")
	dev.LIDMigrationTimestamp = 1234
	must(dev.Save(ctx), "device.Save again")

	// Our own message tables, in the same file: a synthetic decoded
	// history-sync blob and a live message.
	_, err = db.Exec(`CREATE TABLE IF NOT EXISTS comms_message (id INTEGER PRIMARY KEY, chat TEXT, body TEXT, raw BLOB)`)
	must(err, "create comms_message")
	_, err = db.Exec(`CREATE INDEX IF NOT EXISTS comms_message_body ON comms_message(body)`)
	must(err, "index")
	hs := &waHistorySync.HistorySync{
		SyncType: waHistorySync.HistorySync_INITIAL_BOOTSTRAP.Enum(),
		Conversations: []*waHistorySync.Conversation{{
			ID:   proto.String(peerJID.String()),
			Name: proto.String(c("history-conversation-name")),
			Messages: []*waHistorySync.HistorySyncMsg{{Message: &waWeb.WebMessageInfo{
				Key:     &waCommon.MessageKey{RemoteJID: proto.String(peerJID.String()), FromMe: proto.Bool(false), ID: proto.String(c("hist-msgid"))},
				Message: &waE2E.Message{Conversation: proto.String(c("history-sync-message-body"))},
			}}},
		}},
	}
	hsRaw, err := proto.Marshal(hs)
	must(err, "marshal history sync")
	_, err = db.Exec(`INSERT INTO comms_message (chat, body, raw) VALUES (?, ?, ?), (?, ?, ?)`,
		peerJID.String(), c("history-sync-message-body"), hsRaw,
		peerJID.String(), c("live-message-body"), []byte(c("live-message-raw")))
	must(err, "insert comms_message")
	fmt.Println("write: all store interfaces exercised OK")
}

// rawDB opens a second pool on the same file through the same keyed driver,
// for our own tables and for pragma inspection.
func rawDB(dataDir string) *sql.DB {
	db, err := sql.Open(driverName, "file:"+filepath.Join(dataDir, "comms.db")+dsnSuffix())
	must(err, "sql.Open raw")
	return db
}

func doLoop(ctx context.Context, dataDir string) {
	container := openContainer(ctx, dataDir, defaultPragmas)
	dev, err := container.GetDevice(ctx, ownJID)
	must(err, "GetDevice")
	if dev == nil {
		must(fmt.Errorf("device not found"), "GetDevice")
	}
	db := rawDB(dataDir)
	filler := strings.Repeat("CANARY-WA-loop-filler-", 200)
	for i := 0; ; i++ {
		addr := fmt.Sprintf("canaryloop%d.0:1", i%500)
		must(dev.Sessions.PutSession(ctx, addr, []byte(fmt.Sprintf("%s-%d-%s", c("loop-session"), i, filler))), "loop PutSession")
		k := seedBytes(fmt.Sprintf("loop-identity-%d", i%500))
		must(dev.Identities.PutIdentity(ctx, addr, k), "loop PutIdentity")
		tx, err := db.Begin()
		must(err, "begin")
		for j := 0; j < 20; j++ {
			_, err = tx.Exec(`INSERT INTO comms_message (chat, body, raw) VALUES (?, ?, ?)`, peerJID.String(), fmt.Sprintf("%s-%d-%d", c("loop-message-body"), i, j), []byte(filler))
			must(err, "loop insert")
		}
		must(tx.Commit(), "commit")
		if i%50 == 0 {
			fmt.Println("loop iteration", i)
		}
	}
}

// doDump decrypts the database and prints every distinct stored value of at
// least 12 bytes as hex, one per line, for the needle search.
func doDump(ctx context.Context, dataDir string) {
	registerCipherDriver(driverName, dbKeyHex(), []string{"PRAGMA query_only = ON"})
	db := rawDB(dataDir)
	defer db.Close()
	var ic string
	must(db.QueryRow("PRAGMA integrity_check").Scan(&ic), "integrity_check")
	fmt.Fprintln(os.Stderr, "integrity_check:", ic)
	rows, err := db.Query(`SELECT name FROM sqlite_master WHERE type='table' ORDER BY name`)
	must(err, "list tables")
	var tables []string
	for rows.Next() {
		var t string
		must(rows.Scan(&t), "scan")
		tables = append(tables, t)
	}
	rows.Close()
	seen := map[string]bool{}
	for _, t := range tables {
		r, err := db.Query(fmt.Sprintf(`SELECT * FROM "%s"`, t))
		must(err, "select "+t)
		cols, _ := r.Columns()
		count := 0
		for r.Next() {
			count++
			vals := make([]any, len(cols))
			ptrs := make([]any, len(cols))
			for i := range vals {
				ptrs[i] = &vals[i]
			}
			must(r.Scan(ptrs...), "scan row")
			for _, v := range vals {
				var b []byte
				switch x := v.(type) {
				case []byte:
					b = x
				case string:
					b = []byte(x)
				}
				if len(b) >= 12 {
					seen[hex.EncodeToString(b)] = true
				}
			}
		}
		r.Close()
		fmt.Fprintf(os.Stderr, "table %-40s rows=%d\n", t, count)
	}
	// Also the deterministic key material and derived public keys.
	for _, f := range []string{"noise-priv", "identity-priv", "adv-secret", "account-signature-key", "peer-identity", "app-state-sync-key", "message-secret", "message-secret-history", "privacy-token", "nct-salt", "sqlcipher-db-key"} {
		b := seedBytes(f)
		seen[hex.EncodeToString(b[:])] = true
	}
	for _, f := range []string{"noise-priv", "identity-priv"} {
		kp := keys.NewKeyPairFromPrivateKey(seedBytes(f))
		seen[hex.EncodeToString(kp.Pub[:])] = true
	}
	out := make([]string, 0, len(seen))
	for k := range seen {
		out = append(out, k)
	}
	sort.Strings(out)
	for _, k := range out {
		fmt.Println(k)
	}
}

func doBadKey(dataDir string) {
	// Wrong key through the cipher driver: must fail.
	k := seedBytes("WRONG")
	registerCipherDriver("sqlite3-wrongkey", hex.EncodeToString(k[:]), nil)
	db, _ := sql.Open("sqlite3-wrongkey", "file:"+filepath.Join(dataDir, "comms.db")+dsnSuffix())
	var n int
	err := db.QueryRow(`SELECT count(*) FROM sqlite_master`).Scan(&n)
	fmt.Println("wrong key -> err:", err)
}

func hexOf(b [32]byte) string { return hex.EncodeToString(b[:]) }

func pad32(s string) []byte {
	b := make([]byte, 32)
	copy(b, s+"________________________________")
	return b
}

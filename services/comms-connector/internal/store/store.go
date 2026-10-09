// Package store is the per-connection SQLCipher database: chats, messages and
// the hash-chained access log, all in one encrypted file.
//
// Rules from the slice 0 probe (§6b):
//   - the key goes in the DSN, applied inside the driver's Open before any
//     page is read; never in the ConnectHook (that breaks every reopen);
//   - the ConnectHook sets the per-connection pragmas on every pooled
//     connection;
//   - the DSN never reaches a log, an error or a %v: it lives only inside
//     keyedConnector, whose formatting is redacted, and every open error is
//     replaced by ErrOpen.
package store

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/hex"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"sync"
	"time"

	sqlite3 "github.com/mattn/go-sqlite3" // replaced by jgiannuzzi/go-sqlite3 (sqlite3mc 2.2.7), see go.mod

	"services/comms-connector/internal/provider"
)

// DriverName is the registered driver. whatsmeow's dbutil maps any name
// starting with "sqlite" to the SQLite dialect, which slice 4 relies on.
const DriverName = "sqlite3-comms"

var (
	// ErrOpen is the only error Open returns. The driver's own errors are
	// discarded because the open path is where the DSN is parsed.
	ErrOpen = errors.New("open comms store failed")
	// ErrStore is returned for any later database failure.
	ErrStore = errors.New("comms store operation failed")
	// ErrAccessLog is returned when the access-log append did not commit.
	ErrAccessLog = errors.New("access log append failed")
	// ErrBadInput is returned for rows that fail validation before writing.
	ErrBadInput = errors.New("invalid store input")
)

// connectPragmas run on every pooled connection, after the driver has
// applied the key.
var connectPragmas = []string{
	"PRAGMA foreign_keys = ON",
	"PRAGMA journal_mode = WAL",
	"PRAGMA temp_store = MEMORY",
	"PRAGMA secure_delete = ON",
	"PRAGMA synchronous = FULL",
	"PRAGMA busy_timeout = 5000",
}

var (
	registerOnce sync.Once
	registered   driver.Driver
)

func cipherDriver() driver.Driver {
	registerOnce.Do(func() {
		d := &sqlite3.SQLiteDriver{
			ConnectHook: func(c *sqlite3.SQLiteConn) error {
				for _, p := range connectPragmas {
					if _, err := c.Exec(p, nil); err != nil {
						return errHook
					}
				}
				return nil
			},
		}
		sql.Register(DriverName, d)
		registered = d
	})
	return registered
}

var errHook = errors.New("connection setup failed")

// keyedConnector opens connections with the DSN. The DSN exists only inside
// the open closure: fmt prints a func as an address and never looks inside
// it. (A plain string field is not enough: fmt's bad-verb path, e.g.
// fmt.Sprintf("%s", db) on the *sql.DB, dereferences the connector struct and
// prints unexported fields, bypassing any Format method.)
type keyedConnector struct {
	open func() (driver.Conn, error)
	d    driver.Driver
}

func newKeyedConnector(dsn string, d driver.Driver) keyedConnector {
	return keyedConnector{
		open: func() (driver.Conn, error) { return d.Open(dsn) },
		d:    d,
	}
}

func (k keyedConnector) Connect(context.Context) (driver.Conn, error) {
	c, err := k.open()
	if err != nil {
		return nil, ErrOpen
	}
	return c, nil
}
func (k keyedConnector) Driver() driver.Driver    { return k.d }
func (keyedConnector) String() string             { return "comms-store-connector" }
func (keyedConnector) GoString() string           { return "comms-store-connector" }
func (keyedConnector) Format(f fmt.State, _ rune) { _, _ = f.Write([]byte("comms-store-connector")) }

// Store is one open per-connection database.
type Store struct {
	db    *sql.DB
	logMu sync.Mutex // serialises access-log appends inside this process
}

func (s *Store) String() string             { return "comms-store" }
func (s *Store) GoString() string           { return "comms-store" }
func (s *Store) Format(f fmt.State, _ rune) { _, _ = f.Write([]byte("comms-store")) }

func buildDSN(path string, key []byte) (string, bool) {
	// No "file:" prefix: the driver then passes only the path (everything
	// before '?') to sqlite3_open_v2, so the key never becomes part of the
	// SQLite filename/URI.
	if path == "" || strings.ContainsAny(path, "?#") || strings.HasPrefix(path, "file:") || len(key) != 32 {
		return "", false
	}
	q := "_cipher=sqlcipher&_legacy=4" +
		"&_key=" + url.QueryEscape("x'"+hex.EncodeToString(key)+"'") +
		"&_sync=FULL&_txlock=immediate&_busy_timeout=5000"
	return path + "?" + q, true
}

// Open opens (creating if needed) the encrypted store at path with a 32-byte
// SQLCipher key. A wrong key, a plaintext file, a build without
// SQLITE_TEMP_STORE=3 or any pragma that did not take all yield ErrOpen.
func Open(ctx context.Context, path string, key []byte) (*Store, error) {
	dsn, ok := buildDSN(path, key)
	if !ok {
		return nil, ErrOpen
	}
	db := sql.OpenDB(newKeyedConnector(dsn, cipherDriver()))
	db.SetMaxOpenConns(4)
	db.SetMaxIdleConns(4)
	s := &Store{db: db}
	if err := s.init(ctx); err != nil {
		db.Close()
		return nil, ErrOpen
	}
	return s, nil
}

func (s *Store) Close() error {
	if err := s.db.Close(); err != nil {
		return ErrStore
	}
	return nil
}

const schema = `
CREATE TABLE IF NOT EXISTS chats (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS messages (
  id          TEXT PRIMARY KEY,
  chat_id     TEXT NOT NULL REFERENCES chats(id),
  chat_name   TEXT NOT NULL,
  sender_name TEXT NOT NULL,
  body        TEXT NOT NULL,
  sent_at     INTEGER NOT NULL,
  stored_at   INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS messages_chat_sent ON messages(chat_id, sent_at DESC, id DESC);
CREATE TABLE IF NOT EXISTS access_log (
  seq            INTEGER PRIMARY KEY,
  prev_hash      BLOB NOT NULL CHECK (length(prev_hash) = 32),
  hash           BLOB NOT NULL CHECK (length(hash) = 32),
  principal      TEXT NOT NULL,
  api_key_id     TEXT NOT NULL,
  run_id         TEXT NOT NULL,
  ticket_id      TEXT NOT NULL UNIQUE,
  grant_id       TEXT NOT NULL,
  access_epoch   INTEGER NOT NULL,
  key_generation INTEGER NOT NULL,
  scope          TEXT NOT NULL,
  row_count      INTEGER NOT NULL,
  at_unix_ms     INTEGER NOT NULL
);
`

func (s *Store) init(ctx context.Context) error {
	// Touch the database first: with a wrong key this is where it fails.
	var n int
	if err := s.db.QueryRowContext(ctx, "SELECT count(*) FROM sqlite_master").Scan(&n); err != nil {
		return err
	}
	if err := s.checkBuild(ctx); err != nil {
		return err
	}
	if err := s.CheckPragmas(ctx); err != nil {
		return err
	}
	_, err := s.db.ExecContext(ctx, schema)
	return err
}

// checkBuild refuses a binary compiled without -DSQLITE_TEMP_STORE=3.
func (s *Store) checkBuild(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, "PRAGMA compile_options")
	if err != nil {
		return err
	}
	defer rows.Close()
	found := false
	for rows.Next() {
		var opt string
		if err := rows.Scan(&opt); err != nil {
			return err
		}
		if opt == "TEMP_STORE=3" {
			found = true
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if !found {
		return errors.New("built without SQLITE_TEMP_STORE=3")
	}
	return nil
}

// Pragmas is what one pooled connection reports.
type Pragmas struct {
	ForeignKeys  int
	JournalMode  string
	TempStore    int
	SecureDelete int
	Synchronous  int
}

// ConnPragmas reads the pragmas on one specific pooled connection.
func ConnPragmas(ctx context.Context, c *sql.Conn) (Pragmas, error) {
	var p Pragmas
	q := func(stmt string, dst any) error { return c.QueryRowContext(ctx, stmt).Scan(dst) }
	if err := q("PRAGMA foreign_keys", &p.ForeignKeys); err != nil {
		return p, ErrStore
	}
	if err := q("PRAGMA journal_mode", &p.JournalMode); err != nil {
		return p, ErrStore
	}
	if err := q("PRAGMA temp_store", &p.TempStore); err != nil {
		return p, ErrStore
	}
	if err := q("PRAGMA secure_delete", &p.SecureDelete); err != nil {
		return p, ErrStore
	}
	if err := q("PRAGMA synchronous", &p.Synchronous); err != nil {
		return p, ErrStore
	}
	return p, nil
}

// Want is the required pragma state of every connection.
var Want = Pragmas{ForeignKeys: 1, JournalMode: "wal", TempStore: 2, SecureDelete: 1, Synchronous: 2}

// CheckPragmas verifies Want on one pooled connection.
func (s *Store) CheckPragmas(ctx context.Context) error {
	c, err := s.db.Conn(ctx)
	if err != nil {
		return ErrStore
	}
	defer c.Close()
	p, err := ConnPragmas(ctx, c)
	if err != nil {
		return err
	}
	if p != Want {
		return errors.New("pragma state not as required")
	}
	return nil
}

// Conn exposes one pooled connection (tests use it to check every connection).
func (s *Store) Conn(ctx context.Context) (*sql.Conn, error) {
	c, err := s.db.Conn(ctx)
	if err != nil {
		return nil, ErrStore
	}
	return c, nil
}

// PutChat upserts a chat.
func (s *Store) PutChat(ctx context.Context, c provider.Chat) error {
	if c.ID == "" {
		return ErrBadInput
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO chats (id, name, updated_at) VALUES (?, ?, ?)
		 ON CONFLICT(id) DO UPDATE SET name = excluded.name,
		   updated_at = max(chats.updated_at, excluded.updated_at)`,
		c.ID, c.Name, c.UpdatedAt.UnixMilli())
	if err != nil {
		return ErrStore
	}
	return nil
}

// PutMessage inserts a message; a message ID already present is left as is.
func (s *Store) PutMessage(ctx context.Context, m provider.Message) error {
	if m.ID == "" || m.ChatID == "" {
		return ErrBadInput
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO messages (id, chat_id, chat_name, sender_name, body, sent_at, stored_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING`,
		m.ID, m.ChatID, m.ChatName, m.SenderName, m.Body, m.SentAt.UnixMilli(), time.Now().UnixMilli())
	if err != nil {
		return ErrStore
	}
	return nil
}

// ListChats returns at most max chats, most recently updated first.
func (s *Store) ListChats(ctx context.Context, max int) ([]provider.Chat, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, name, updated_at FROM chats ORDER BY updated_at DESC, id ASC LIMIT ?`, max)
	if err != nil {
		return nil, ErrStore
	}
	defer rows.Close()
	out := []provider.Chat{}
	for rows.Next() {
		var c provider.Chat
		var ms int64
		if err := rows.Scan(&c.ID, &c.Name, &ms); err != nil {
			return nil, ErrStore
		}
		c.UpdatedAt = time.UnixMilli(ms).UTC()
		out = append(out, c)
	}
	if rows.Err() != nil {
		return nil, ErrStore
	}
	return out, nil
}

// ListMessages returns the newest limit messages of one chat, newest first.
func (s *Store) ListMessages(ctx context.Context, chatID string, limit int) ([]provider.Message, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, chat_id, chat_name, sender_name, body, sent_at FROM messages
		 WHERE chat_id = ? ORDER BY sent_at DESC, id DESC LIMIT ?`, chatID, limit)
	if err != nil {
		return nil, ErrStore
	}
	defer rows.Close()
	out := []provider.Message{}
	for rows.Next() {
		var m provider.Message
		var ms int64
		if err := rows.Scan(&m.ID, &m.ChatID, &m.ChatName, &m.SenderName, &m.Body, &ms); err != nil {
			return nil, ErrStore
		}
		m.SentAt = time.UnixMilli(ms).UTC()
		out = append(out, m)
	}
	if rows.Err() != nil {
		return nil, ErrStore
	}
	return out, nil
}

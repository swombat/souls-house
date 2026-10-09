package store

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/binary"
	"errors"
	"fmt"
	"time"
)

// AccessEntry is one access-log record. It never holds content: no bodies,
// no names, no JIDs. Scope names the endpoint, the opaque chat ID and the
// row limit.
type AccessEntry struct {
	Seq           uint64
	PrevHash      []byte
	Hash          []byte
	Principal     string
	APIKeyID      string
	RunID         string
	TicketID      string
	GrantID       string
	AccessEpoch   uint64
	KeyGeneration uint64
	Scope         string
	RowCount      uint64
	At            time.Time // stored at millisecond precision
}

const accessLogDomain = "comms-access-log-v1"

func lpAppend(out []byte, s string) []byte {
	out = binary.BigEndian.AppendUint32(out, uint32(len(s)))
	return append(out, s...)
}

// CanonicalEncoding is the unambiguous byte encoding of an entry (all fields
// except the hashes): length-prefixed strings and big-endian integers in a
// fixed order.
func CanonicalEncoding(e AccessEntry) []byte {
	out := lpAppend(nil, accessLogDomain)
	out = binary.BigEndian.AppendUint64(out, e.Seq)
	out = lpAppend(out, e.Principal)
	out = lpAppend(out, e.APIKeyID)
	out = lpAppend(out, e.RunID)
	out = lpAppend(out, e.TicketID)
	out = lpAppend(out, e.GrantID)
	out = binary.BigEndian.AppendUint64(out, e.AccessEpoch)
	out = binary.BigEndian.AppendUint64(out, e.KeyGeneration)
	out = lpAppend(out, e.Scope)
	out = binary.BigEndian.AppendUint64(out, e.RowCount)
	out = binary.BigEndian.AppendUint64(out, uint64(e.At.UnixMilli()))
	return out
}

// EntryHash = SHA-256(prev_hash || CanonicalEncoding(entry)).
func EntryHash(prev []byte, e AccessEntry) []byte {
	h := sha256.New()
	h.Write(prev)
	h.Write(CanonicalEncoding(e))
	return h.Sum(nil)
}

// GenesisHash is the prev_hash of entry 1.
var GenesisHash = make([]byte, sha256.Size)

// AppendAccess appends e (Seq, PrevHash, Hash and, if zero, At are filled in)
// in one committed transaction. With synchronous=FULL the commit is durable
// when this returns nil. Any failure returns ErrAccessLog and nothing is
// written.
func (s *Store) AppendAccess(ctx context.Context, e AccessEntry) (AccessEntry, error) {
	s.logMu.Lock()
	defer s.logMu.Unlock()
	if e.At.IsZero() {
		e.At = time.Now()
	}
	e.At = time.UnixMilli(e.At.UnixMilli()).UTC()
	tx, err := s.db.BeginTx(ctx, nil) // BEGIN IMMEDIATE via _txlock
	if err != nil {
		return AccessEntry{}, ErrAccessLog
	}
	defer tx.Rollback()
	var lastSeq uint64
	var lastHash []byte
	err = tx.QueryRowContext(ctx, `SELECT seq, hash FROM access_log ORDER BY seq DESC LIMIT 1`).Scan(&lastSeq, &lastHash)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		lastSeq, lastHash = 0, GenesisHash
	case err != nil:
		return AccessEntry{}, ErrAccessLog
	}
	e.Seq = lastSeq + 1
	e.PrevHash = append([]byte(nil), lastHash...)
	e.Hash = EntryHash(e.PrevHash, e)
	_, err = tx.ExecContext(ctx,
		`INSERT INTO access_log (seq, prev_hash, hash, principal, api_key_id, run_id, ticket_id,
		   grant_id, access_epoch, key_generation, scope, row_count, at_unix_ms)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		int64(e.Seq), e.PrevHash, e.Hash, e.Principal, e.APIKeyID, e.RunID, e.TicketID,
		e.GrantID, int64(e.AccessEpoch), int64(e.KeyGeneration), e.Scope, int64(e.RowCount), e.At.UnixMilli())
	if err != nil {
		return AccessEntry{}, ErrAccessLog
	}
	if err := tx.Commit(); err != nil {
		return AccessEntry{}, ErrAccessLog
	}
	return e, nil
}

// AccessLog returns every entry in seq order.
func (s *Store) AccessLog(ctx context.Context) ([]AccessEntry, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT seq, prev_hash, hash, principal, api_key_id, run_id, ticket_id, grant_id,
		   access_epoch, key_generation, scope, row_count, at_unix_ms
		 FROM access_log ORDER BY seq ASC`)
	if err != nil {
		return nil, ErrStore
	}
	defer rows.Close()
	var out []AccessEntry
	for rows.Next() {
		var e AccessEntry
		var seq, epoch, gen, rc, ms int64
		if err := rows.Scan(&seq, &e.PrevHash, &e.Hash, &e.Principal, &e.APIKeyID, &e.RunID,
			&e.TicketID, &e.GrantID, &epoch, &gen, &e.Scope, &rc, &ms); err != nil {
			return nil, ErrStore
		}
		e.Seq, e.AccessEpoch, e.KeyGeneration, e.RowCount = uint64(seq), uint64(epoch), uint64(gen), uint64(rc)
		e.At = time.UnixMilli(ms).UTC()
		out = append(out, e)
	}
	if rows.Err() != nil {
		return nil, ErrStore
	}
	return out, nil
}

// VerifyChain checks that entries are numbered 1..n without gaps, that each
// prev_hash is the previous hash (genesis for the first), and that each hash
// recomputes. It reports the first bad seq. It cannot detect a rewrite of
// the whole chain by someone holding the store key (spec §3: no independent
// anchor).
func VerifyChain(entries []AccessEntry) error {
	prev := GenesisHash
	for i, e := range entries {
		if e.Seq != uint64(i+1) {
			return fmt.Errorf("access log: sequence break at position %d", i+1)
		}
		if !bytes.Equal(e.PrevHash, prev) {
			return fmt.Errorf("access log: prev_hash mismatch at seq %d", e.Seq)
		}
		if !bytes.Equal(e.Hash, EntryHash(prev, e)) {
			return fmt.Errorf("access log: hash mismatch at seq %d", e.Seq)
		}
		prev = e.Hash
	}
	return nil
}

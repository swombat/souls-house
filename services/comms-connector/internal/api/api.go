// Package api serves the ticketed read API (spec §3) on the private network.
//
//	GET /v1/connections/{ref}/chats
//	GET /v1/connections/{ref}/messages?chat=<id>&limit=<n>
//
// Order for every read: route and parameter checks, ticket verification
// (signature, expiry, connection, key generation, request digest), consume at
// Rails, read rows from the open store, append the access-log entry in a
// committed transaction, and only then write the response. A failure at any
// step returns a fixed string and releases nothing.
package api

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log"
	"log/slog"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"services/comms-connector/internal/ids"
	"services/comms-connector/internal/provider"
	"services/comms-connector/internal/store"
	"services/comms-connector/internal/ticket"
)

const (
	TicketHeader = "X-Comms-Ticket"
	// MaxChats bounds the chats endpoint; MaxLimit bounds messages?limit=.
	MaxChats = 200
	MaxLimit = 200
)

// Reader is the store surface the API needs. *store.Store implements it;
// tests substitute a failing AppendAccess.
type Reader interface {
	ListChats(ctx context.Context, max int) ([]provider.Chat, error)
	ListMessages(ctx context.Context, chatID string, limit int) ([]provider.Message, error)
	AppendAccess(ctx context.Context, e store.AccessEntry) (store.AccessEntry, error)
}

// Consumer is the Rails consume call.
type Consumer interface {
	Consume(ctx context.Context, ticketID, header string) error
}

type Config struct {
	ConnectionRef string
	KeyGeneration uint64
	Secret        ticket.Secret
	Consumer      Consumer
	Store         Reader
	Log           *slog.Logger
	// LogID is the keyed hash that stands for the connection in logs.
	LogID string
	Now   func() time.Time
}

type Server struct{ c Config }

func New(c Config) *Server {
	if c.Now == nil {
		c.Now = time.Now
	}
	return &Server{c: c}
}

// Fixed response bodies. Nothing from the request is ever echoed.
const (
	msgBadRequest  = "bad request\n"
	msgNotFound    = "not found\n"
	msgMethod      = "method not allowed\n"
	msgForbidden   = "forbidden\n"
	msgUnavailable = "unavailable\n"
	msgInternal    = "internal error\n"
)

var limitRe = regexp.MustCompile(`^[1-9][0-9]{0,2}$`)

type chatJSON struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	UpdatedAt string `json:"updated_at"`
}

type messageJSON struct {
	ID         string `json:"id"`
	ChatID     string `json:"chat_id"`
	ChatName   string `json:"chat_name"`
	SenderName string `json:"sender_name"`
	Body       string `json:"body"`
	SentAt     string `json:"sent_at"`
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Set("Cache-Control", "no-store")
	h.Set("X-Content-Type-Options", "nosniff")
	start := s.c.Now()
	status, reason, rows := http.StatusInternalServerError, "panic", 0
	defer func() {
		if p := recover(); p != nil {
			// The panic value is deliberately not logged.
			writeFixed(w, http.StatusInternalServerError, msgInternal)
			status, reason = http.StatusInternalServerError, "panic"
		}
		s.c.Log.Info("read",
			slog.String("conn", s.c.LogID),
			slog.Int("status", status),
			slog.String("reason", reason),
			slog.Int("rows", rows),
			slog.Int64("dur_ms", s.c.Now().Sub(start).Milliseconds()))
	}()
	status, reason, rows = s.serve(w, r)
}

func writeFixed(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(status)
	_, _ = io.WriteString(w, msg)
}

func fail(w http.ResponseWriter, status int, msg, reason string) (int, string, int) {
	writeFixed(w, status, msg)
	return status, reason, 0
}

func (s *Server) serve(w http.ResponseWriter, r *http.Request) (int, string, int) {
	if r.Method != http.MethodGet {
		return fail(w, http.StatusMethodNotAllowed, msgMethod, "method")
	}
	// Exact routing, no ServeMux: ServeMux answers unclean paths with a
	// redirect whose Location echoes the request.
	if r.URL.RawPath != "" {
		return fail(w, http.StatusNotFound, msgNotFound, "route")
	}
	parts := strings.Split(r.URL.Path, "/")
	if len(parts) != 5 || parts[0] != "" || parts[1] != "v1" || parts[2] != "connections" {
		return fail(w, http.StatusNotFound, msgNotFound, "route")
	}
	ref, kind := parts[3], parts[4]
	if kind != "chats" && kind != "messages" {
		return fail(w, http.StatusNotFound, msgNotFound, "route")
	}
	if !ids.ValidConnectionRef(ref) ||
		subtle.ConstantTimeCompare([]byte(ref), []byte(s.c.ConnectionRef)) != 1 {
		return fail(w, http.StatusNotFound, msgNotFound, "route_connection")
	}
	canon, q, ok := ticket.CanonicalQuery(r.URL.RawQuery)
	if !ok {
		return fail(w, http.StatusBadRequest, msgBadRequest, "query")
	}
	var chatID string
	var limit int
	switch kind {
	case "chats":
		if len(q) != 0 {
			return fail(w, http.StatusBadRequest, msgBadRequest, "query")
		}
	case "messages":
		if len(q) != 2 || q.Get("chat") == "" || q.Get("limit") == "" {
			return fail(w, http.StatusBadRequest, msgBadRequest, "query")
		}
		chatID = q.Get("chat")
		if !ids.ValidChatID(chatID) || !limitRe.MatchString(q.Get("limit")) {
			return fail(w, http.StatusBadRequest, msgBadRequest, "query")
		}
		limit, _ = strconv.Atoi(q.Get("limit"))
		if limit > MaxLimit {
			return fail(w, http.StatusBadRequest, msgBadRequest, "query")
		}
	}

	header := r.Header.Values(TicketHeader)
	if len(header) != 1 {
		return fail(w, http.StatusForbidden, msgForbidden, ticket.ReasonMalformed)
	}
	claims, err := ticket.Verify(s.c.Secret, header[0], ticket.Expect{
		ConnectionRef: s.c.ConnectionRef,
		KeyGeneration: s.c.KeyGeneration,
		Digest:        ticket.Digest(r.Method, r.URL.EscapedPath(), canon),
		Now:           s.c.Now(),
	})
	if err != nil {
		return fail(w, http.StatusForbidden, msgForbidden, reasonOf(err))
	}

	// Re-validation at release. Only an explicit allow continues.
	if err := s.c.Consumer.Consume(r.Context(), claims.TicketID, header[0]); err != nil {
		if reasonOf(err) == ticket.ReasonConsumeErr {
			return fail(w, http.StatusServiceUnavailable, msgUnavailable, ticket.ReasonConsumeErr)
		}
		return fail(w, http.StatusForbidden, msgForbidden, ticket.ReasonConsume)
	}

	// Read from the open SQLCipher store and build the response in memory.
	var body []byte
	var n int
	var scope string
	switch kind {
	case "chats":
		chats, err := s.c.Store.ListChats(r.Context(), MaxChats)
		if err != nil {
			return fail(w, http.StatusInternalServerError, msgInternal, "store")
		}
		out := make([]chatJSON, 0, len(chats))
		for _, c := range chats {
			out = append(out, chatJSON{ID: c.ID, Name: c.Name, UpdatedAt: c.UpdatedAt.UTC().Format(time.RFC3339)})
		}
		body, err = json.Marshal(struct {
			Chats []chatJSON `json:"chats"`
		}{out})
		if err != nil {
			return fail(w, http.StatusInternalServerError, msgInternal, "encode")
		}
		n, scope = len(out), "chats:max="+strconv.Itoa(MaxChats)
	case "messages":
		msgs, err := s.c.Store.ListMessages(r.Context(), chatID, limit)
		if err != nil {
			return fail(w, http.StatusInternalServerError, msgInternal, "store")
		}
		out := make([]messageJSON, 0, len(msgs))
		for _, m := range msgs {
			out = append(out, messageJSON{ID: m.ID, ChatID: m.ChatID, ChatName: m.ChatName,
				SenderName: m.SenderName, Body: m.Body, SentAt: m.SentAt.UTC().Format(time.RFC3339)})
		}
		body, err = json.Marshal(struct {
			Messages []messageJSON `json:"messages"`
		}{out})
		if err != nil {
			return fail(w, http.StatusInternalServerError, msgInternal, "encode")
		}
		n, scope = len(out), "messages:chat="+chatID+":limit="+strconv.Itoa(limit)
	}

	// Durable access-log entry before any row leaves the process.
	if _, err := s.c.Store.AppendAccess(r.Context(), store.AccessEntry{
		Principal:     claims.Principal,
		APIKeyID:      claims.APIKeyID,
		RunID:         claims.RunID,
		TicketID:      claims.TicketID,
		GrantID:       claims.GrantID,
		AccessEpoch:   claims.AccessEpoch,
		KeyGeneration: claims.KeyGeneration,
		Scope:         scope,
		RowCount:      uint64(n),
		At:            s.c.Now(),
	}); err != nil {
		return fail(w, http.StatusInternalServerError, msgInternal, "access_log")
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
	return http.StatusOK, "released", n
}

func reasonOf(err error) string {
	var te *ticket.Error
	if errors.As(err, &te) {
		return te.Reason
	}
	return "error"
}

// NewHTTPServer wraps the handler with timeouts and an http.Server whose own
// error log is discarded (it would otherwise print panic values and
// malformed-request details to stderr).
func NewHTTPServer(addr string, h http.Handler) *http.Server {
	return &http.Server{
		Addr:              addr,
		Handler:           h,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 << 10,
		ErrorLog:          log.New(io.Discard, "", 0),
	}
}

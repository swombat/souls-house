package server

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"

	"services/comms-connector/internal/command"
	"services/comms-connector/internal/ids"
	"services/comms-connector/internal/worker"
)

// MaxCommandBytes bounds a command body; the largest (start_pairing) is
// well under 1 KiB.
const MaxCommandBytes = 16 << 10

// Commands is what the handler drives (the Manager).
type Commands interface {
	StartPairing(ctx context.Context, ref, secret string, version int64) error
	Unpair(ctx context.Context, ref string) error
}

type Handler struct {
	Verifier *command.Verifier
	Commands Commands
	Log      *slog.Logger
}

// ServeHTTP: POST /connections/{ref}/{start_pairing|unpair}, GET /healthz.
// Bodies are never logged; refusals log a fixed code.
func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet && r.URL.Path == "/healthz" {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
		return
	}
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/"), "/")
	if r.Method != http.MethodPost || len(parts) != 3 || parts[0] != "connections" || !ids.ValidConnectionRef(parts[1]) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	ref, op := parts[1], parts[2]
	if op != "start_pairing" && op != "unpair" {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "unknown_operation"})
		return
	}
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, MaxCommandBytes))
	if err != nil {
		h.refuse(w, op, "body_too_large", http.StatusRequestEntityTooLarge)
		return
	}
	cmd, err := h.Verifier.Verify(ref, op, r.Header, raw)
	clear(raw)
	var refused *command.Refused
	if errors.As(err, &refused) {
		h.refuse(w, op, refused.Code, http.StatusUnauthorized)
		return
	}
	if err != nil {
		h.refuse(w, op, "verify_failed", http.StatusUnauthorized)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 25*time.Second)
	defer cancel()
	switch op {
	case "start_pairing":
		if cmd.CallbackSecret == "" || len(cmd.CallbackSecret) > 256 {
			h.refuse(w, op, "bad_secret", http.StatusUnprocessableEntity)
			return
		}
		version := max(cmd.CallbackSecretVersion, 1)
		err = h.Commands.StartPairing(ctx, ref, cmd.CallbackSecret, version)
		if errors.Is(err, worker.ErrStaleSecret) {
			h.refuse(w, op, "stale_secret_version", http.StatusConflict)
			return
		}
		if err != nil {
			h.refuse(w, op, "start_failed", http.StatusInternalServerError)
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "pairing"})
	case "unpair":
		if err := h.Commands.Unpair(ctx, ref); err != nil {
			h.refuse(w, op, "unpair_failed", http.StatusInternalServerError)
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "unpaired"})
	}
}

func (h *Handler) refuse(w http.ResponseWriter, op, code string, status int) {
	h.Log.Warn("command refused", slog.String("op", op), slog.String("reason", code))
	writeJSON(w, status, map[string]string{"error": code})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

// ErrTLS is the only error TLSConfig returns: paths and parse errors stay out.
var ErrTLS = errors.New("mutual TLS is not configured correctly")

// TLSConfig builds the server side of the mutual TLS Rails expects
// (CommsConnector.tls_options): the connector's certificate, and client
// certificates required and verified against the house CA. clientName,
// when set, must be the client certificate's common name or a DNS SAN.
func TLSConfig(certFile, keyFile, clientCAFile, clientName string) (*tls.Config, error) {
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, ErrTLS
	}
	pem, err := os.ReadFile(clientCAFile)
	if err != nil {
		return nil, ErrTLS
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		return nil, ErrTLS
	}
	cfg := &tls.Config{
		MinVersion:   tls.VersionTLS12,
		Certificates: []tls.Certificate{cert},
		ClientAuth:   tls.RequireAndVerifyClientCert,
		ClientCAs:    pool,
	}
	if clientName != "" {
		cfg.VerifyConnection = func(cs tls.ConnectionState) error {
			if len(cs.PeerCertificates) == 0 {
				return ErrTLS
			}
			leaf := cs.PeerCertificates[0]
			if leaf.Subject.CommonName == clientName {
				return nil
			}
			for _, n := range leaf.DNSNames {
				if n == clientName {
					return nil
				}
			}
			return errors.New("client certificate is not Rails's")
		}
	}
	return cfg, nil
}

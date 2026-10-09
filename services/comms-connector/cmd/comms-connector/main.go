// Command comms-connector runs one connection's worker: lease, envelope,
// encrypted store, provider and the ticketed read API.
//
// Required environment: COMMS_KEK, COMMS_TICKET_SECRET, COMMS_CONSUME_URL.
// GOTRACEBACK must be unset or "none". See README.md.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"services/comms-connector/internal/api"
	"services/comms-connector/internal/harden"
	"services/comms-connector/internal/ids"
	"services/comms-connector/internal/keys"
	"services/comms-connector/internal/lease"
	"services/comms-connector/internal/provider"
	"services/comms-connector/internal/store"
	"services/comms-connector/internal/ticket"
)

func main() { os.Exit(run(os.Args[1:])) }

func envOr(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}

// refuse logs a fixed reason code. It never logs an error string or a value.
func refuse(log *slog.Logger, reason string) int {
	log.Error("startup refused", slog.String("reason", reason))
	return 2
}

func run(args []string) int {
	log := slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))

	if err := harden.Apply(); err != nil {
		if errors.Is(err, harden.ErrTraceback) {
			return refuse(log, "gotraceback")
		}
		return refuse(log, "harden")
	}

	fs := flag.NewFlagSet("comms-connector", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	dataDir := fs.String("data", envOr("COMMS_DATA_DIR", "/data"), "data directory (env COMMS_DATA_DIR)")
	listen := fs.String("listen", os.Getenv("COMMS_LISTEN"), "private listen address host:port (env COMMS_LISTEN); required")
	ref := fs.String("connection", os.Getenv("COMMS_CONNECTION_REF"), "connection ref (env COMMS_CONNECTION_REF); required")
	genStr := fs.String("key-generation", os.Getenv("COMMS_KEY_GENERATION"), "current key generation (env COMMS_KEY_GENERATION); required")
	initConn := fs.Bool("init", false, "create the wrapped DEK for a new connection/generation; refuses if one exists")
	prov := fs.String("provider", "none", "message provider: none | synthetic")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	kek, err := keys.ParseKEK(os.Getenv("COMMS_KEK"))
	if err != nil {
		return refuse(log, "kek")
	}
	secret, err := ticket.NewSecret(os.Getenv("COMMS_TICKET_SECRET"))
	if err != nil {
		return refuse(log, "ticket_secret")
	}
	consumer, err := ticket.NewConsumer(os.Getenv("COMMS_CONSUME_URL"), secret, ticket.DefaultTimeout)
	if err != nil {
		return refuse(log, "consume_url")
	}
	if !ids.ValidConnectionRef(*ref) {
		return refuse(log, "connection_ref")
	}
	gen, err := strconv.ParseUint(*genStr, 10, 64)
	if err != nil || gen == 0 {
		return refuse(log, "key_generation")
	}
	if _, _, err := net.SplitHostPort(*listen); err != nil || *listen == "" {
		return refuse(log, "listen")
	}
	if *prov != "none" && *prov != "synthetic" {
		return refuse(log, "provider")
	}
	logID, err := keys.LogID(kek, *ref)
	if err != nil {
		return refuse(log, "kek")
	}
	baseLog := log
	log = log.With(slog.String("conn", logID))

	connDir, err := keys.ConnDir(*dataDir, *ref)
	if err != nil {
		return refuse(log, "connection_ref")
	}
	if err := os.MkdirAll(connDir, 0o700); err != nil {
		return refuse(log, "data_dir")
	}

	// The lease comes before any key or store access.
	l, err := lease.Acquire(connDir)
	if err != nil {
		if errors.Is(err, lease.ErrHeld) {
			fmt.Fprintln(os.Stderr, "comms-connector: "+lease.ErrHeld.Error())
			return refuse(log, "lease_held")
		}
		return refuse(log, "lease")
	}
	defer l.Release()

	dbPath := filepath.Join(connDir, fmt.Sprintf("store-%d.db", gen))
	var dek []byte
	if *initConn {
		if _, err := os.Stat(dbPath); err == nil {
			return refuse(log, "init_store_exists")
		}
		dek, err = keys.CreateDEK(*dataDir, kek, *ref, gen)
	} else {
		dek, err = keys.LoadDEK(*dataDir, kek, *ref, gen)
	}
	if err != nil {
		return refuse(log, "dek")
	}
	dbKey, err := keys.SQLCipherKey(dek)
	clear(dek)
	if err != nil {
		return refuse(log, "dek")
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	st, err := store.Open(ctx, dbPath, dbKey)
	clear(dbKey)
	if err != nil {
		return refuse(log, "store_open")
	}
	defer st.Close()

	if *prov == "synthetic" {
		go func() {
			if err := provider.DefaultSynthetic().Run(ctx, st); err != nil {
				log.Error("provider", slog.String("reason", "synthetic_failed"))
				return
			}
			log.Info("provider", slog.String("reason", "synthetic_done"))
		}()
	}

	srv := api.NewHTTPServer(*listen, api.New(api.Config{
		ConnectionRef: *ref,
		KeyGeneration: gen,
		Secret:        secret,
		Consumer:      consumer,
		Store:         st,
		Log:           baseLog, // the API adds conn itself
		LogID:         logID,
	}))
	errc := make(chan error, 1)
	go func() { errc <- srv.ListenAndServe() }()
	log.Info("started", slog.Uint64("key_generation", gen))

	select {
	case <-ctx.Done():
	case err := <-errc:
		if !errors.Is(err, http.ErrServerClosed) {
			log.Error("serve", slog.String("reason", "listen_failed"))
			return 1
		}
	}
	sctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(sctx)
	log.Info("stopped")
	return 0
}

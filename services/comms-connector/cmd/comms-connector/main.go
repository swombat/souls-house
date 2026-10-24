// Command comms-connector is the house's WhatsApp connector: a Kamal
// accessory on the private network holding one linked device per
// ServiceConnection, each in its own SQLCipher store on the comms volume.
//
// Rails → connector: start_pairing and unpair over mutual TLS, signed with
// COMMS_COMMAND_KEY. Connector → Rails: signed events to
// COMMS_RAILS_URL/internal/comms/connections/:id/events.
//
// Required environment (see README.md):
//
//	COMMS_STORE_KEY        base64 of 32 bytes; each store's key is HKDF(it, connection)
//	COMMS_COMMAND_KEY      the same value as Rails's COMMS_COMMAND_KEY
//	COMMS_COMMAND_KEY_ID   default k1, as Rails
//	COMMS_RAILS_URL        e.g. http://souls-house-web:80 (private network)
//	COMMS_TLS_CERT, COMMS_TLS_KEY      the connector's certificate and key
//	COMMS_TLS_CLIENT_CA    the house CA that signed Rails's client certificate
//	COMMS_TLS_CLIENT_NAME  optional: the client certificate's CN/SAN (e.g. rails)
//	COMMS_LISTEN           default :8443
//	COMMS_DATA_DIR         default /data
//	COMMS_PROVIDER         whatsapp (default) or synthetic (needs COMMS_ALLOW_SYNTHETIC=1)
//
// GOTRACEBACK must be unset or "none".
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"services/comms-connector/internal/command"
	"services/comms-connector/internal/harden"
	"services/comms-connector/internal/keys"
	"services/comms-connector/internal/provider"
	"services/comms-connector/internal/rails"
	"services/comms-connector/internal/server"
	"services/comms-connector/internal/whatsapp"
	"services/comms-connector/internal/worker"
)

func main() { os.Exit(run()) }

func env(name, def string) string {
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

func run() int {
	log := slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))

	if err := harden.Apply(); err != nil {
		if errors.Is(err, harden.ErrTraceback) {
			return refuse(log, "gotraceback")
		}
		return refuse(log, "harden")
	}

	storeKey, err := keys.ParseStoreKey(os.Getenv("COMMS_STORE_KEY"))
	if err != nil {
		return refuse(log, "store_key")
	}
	commandKey := os.Getenv("COMMS_COMMAND_KEY")
	if len(commandKey) < 32 {
		return refuse(log, "command_key")
	}
	railsClient, err := rails.New(os.Getenv("COMMS_RAILS_URL"), nil)
	if err != nil {
		return refuse(log, "rails_url")
	}
	tlsConfig, err := server.TLSConfig(os.Getenv("COMMS_TLS_CERT"), os.Getenv("COMMS_TLS_KEY"),
		os.Getenv("COMMS_TLS_CLIENT_CA"), os.Getenv("COMMS_TLS_CLIENT_NAME"))
	if err != nil {
		return refuse(log, "tls")
	}
	dataDir := env("COMMS_DATA_DIR", "/data")
	if fi, err := os.Stat(dataDir); err != nil || !fi.IsDir() {
		return refuse(log, "data_dir")
	}

	var factory provider.Factory
	switch env("COMMS_PROVIDER", "whatsapp") {
	case "whatsapp":
		factory = whatsapp.Factory()
	case "synthetic":
		// The log smoke test and the Rails end-to-end test. Never in production.
		if os.Getenv("COMMS_ALLOW_SYNTHETIC") != "1" {
			return refuse(log, "synthetic_not_allowed")
		}
		syn := provider.DefaultSynthetic()
		syn.Marker = os.Getenv("COMMS_SYNTHETIC_MARKER")
		// How many QR codes before the synthetic phone "scans" one: more
		// keeps pairing open long enough to pair by phone number instead.
		if n, err := strconv.Atoi(os.Getenv("COMMS_SYNTHETIC_QR_CODES")); err == nil && n >= 0 && n <= 1000 {
			syn.QRCodes = n
		}
		factory = syn.Factory()
	default:
		return refuse(log, "provider")
	}

	manager := server.NewManager(worker.Config{
		DataDir: dataDir, StoreKey: storeKey, Rails: railsClient, Factory: factory,
	}, log)
	defer manager.Close()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	if err := manager.Boot(ctx); err != nil {
		return refuse(log, "boot")
	}

	srv := &http.Server{
		Addr: env("COMMS_LISTEN", ":8443"),
		Handler: &server.Handler{
			Verifier: command.NewVerifier(env("COMMS_COMMAND_KEY_ID", "k1"), []byte(commandKey), nil),
			Commands: manager,
			Log:      log,
		},
		TLSConfig:         tlsConfig,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		// The server's own error log would print client addresses and TLS
		// errors; it carries no content, but stays quiet like the rest.
		ErrorLog: slog.NewLogLogger(slog.DiscardHandler, slog.LevelError),
	}
	errc := make(chan error, 1)
	go func() { errc <- srv.ListenAndServeTLS("", "") }()
	log.Info("started")

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

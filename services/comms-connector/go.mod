module services/comms-connector

go 1.27.2

require (
	github.com/mattn/go-sqlite3 v1.14.52
	go.mau.fi/libsignal v0.2.2
	go.mau.fi/whatsmeow v0.0.0-20261007111105-c386243a72ba
	golang.org/x/sys v0.48.0
	google.golang.org/protobuf v1.36.12
)

require (
	filippo.io/edwards25519 v1.2.0 // indirect
	github.com/beeper/argo-go v1.1.2 // indirect
	github.com/coder/websocket v1.8.15 // indirect
	github.com/elliotchance/orderedmap/v3 v3.1.0 // indirect
	github.com/google/uuid v1.6.0 // indirect
	github.com/mattn/go-colorable v0.1.14 // indirect
	github.com/mattn/go-isatty v0.0.20 // indirect
	github.com/petermattis/goid v0.0.0-20260820044319-269ab09b5261 // indirect
	github.com/rs/zerolog v1.35.1 // indirect
	github.com/vektah/gqlparser/v2 v2.5.27 // indirect
	go.mau.fi/util v0.10.1 // indirect
	golang.org/x/crypto v0.57.0 // indirect
	golang.org/x/exp v0.0.0-20260908205506-85c1c2202aba // indirect
	golang.org/x/net v0.59.0 // indirect
	golang.org/x/sync v0.23.0 // indirect
	golang.org/x/text v0.42.0 // indirect
)

// Driver B from the slice 0 probe (docs/proposals/evidence/2026-10-09-whatsmeow-sqlcipher):
// SQLite3 Multiple Ciphers 2.2.7 on SQLite 3.51.2, used in SQLCipher v4 mode.
// Pinned by pseudo-version (commit 2c447b9a2806) and by go.sum.
replace github.com/mattn/go-sqlite3 => github.com/jgiannuzzi/go-sqlite3 v1.14.35-0.20260227142656-2c447b9a2806

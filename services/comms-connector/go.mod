module services/comms-connector

go 1.27.2

require (
	github.com/mattn/go-sqlite3 v1.14.52
	golang.org/x/crypto v0.57.0
	golang.org/x/sys v0.48.0
)

// Driver B from the slice 0 probe (docs/proposals/evidence/2026-10-09-whatsmeow-sqlcipher):
// SQLite3 Multiple Ciphers 2.2.7 on SQLite 3.51.2, used in SQLCipher v4 mode.
// Pinned by pseudo-version (commit 2c447b9a2806) and by go.sum.
replace github.com/mattn/go-sqlite3 => github.com/jgiannuzzi/go-sqlite3 v1.14.35-0.20260227142656-2c447b9a2806

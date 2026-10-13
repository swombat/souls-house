# cgo is required (SQLCipher via sqlite3mc), and SQLITE_TEMP_STORE=3 makes
# memory the only temp store. store.Open refuses a binary built without it,
# so a missing flag fails every store test rather than passing silently.
export CGO_ENABLED := 1
export CGO_CFLAGS := -O2 -g -DSQLITE_TEMP_STORE=3

.PHONY: test build vet e2e

test:
	go test -count=1 ./...

vet:
	go vet ./...

build:
	go build -trimpath -o bin/comms-connector ./cmd/comms-connector

# Rails ↔ this binary, end to end, with the synthetic provider (run from the
# repository root's test environment; see README.md).
e2e: build
	cd ../.. && COMMS_CONNECTOR_BIN=services/comms-connector/bin/comms-connector bin/rails test test/integration/comms_whatsapp_connector_e2e_test.rb

//go:build !mc

package main

import (
	"database/sql"
	"fmt"
	"net/url"

	sqlcipher "github.com/mutecomm/go-sqlcipher/v4"
)

const driverLabel = "github.com/mutecomm/go-sqlcipher/v4 v4.4.2 (SQLCipher 4.4.2 community, SQLite 3.33.0)"

// registerCipherDriver registers a driver whose every new connection is keyed
// before anything else touches the file. The name starts with "sqlite" so
// go.mau.fi/util/dbutil.ParseDialect maps it to the SQLite dialect.
func registerCipherDriver(name string, hexKey string, extra []string) {
	// The key is NOT set here: the driver runs PRAGMA synchronous (which loads
	// the schema) before ConnectHook, so keying in the hook fails on an
	// existing file with "file is not a database". The key goes in the DSN
	// (_pragma_key), which the driver applies first. See dsnSuffix.
	pragmas := extra
	currentHexKey = hexKey
	sql.Register(name, &sqlcipher.SQLiteDriver{
		ConnectHook: func(c *sqlcipher.SQLiteConn) error {
			for _, p := range pragmas {
				if _, err := c.Exec(p, nil); err != nil {
					return fmt.Errorf("%s: %w", p, err)
				}
			}
			return nil
		},
	})
}

var currentHexKey string

func dsnSuffix() string {
	return "?_pragma_key=" + url.QueryEscape("x'"+currentHexKey+"'") + "&_pragma_cipher_page_size=4096"
}

const cipherVersionSQL = "PRAGMA cipher_version"

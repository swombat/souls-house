//go:build mc

package main

import (
	"database/sql"
	"fmt"
	"net/url"

	sqlite3 "github.com/mattn/go-sqlite3" // replaced by jgiannuzzi/go-sqlite3 sqlite3mc-2.2.7 branch
)

const driverLabel = "github.com/jgiannuzzi/go-sqlite3 @ sqlite3mc-2.2.7 (SQLite3 Multiple Ciphers 2.2.7, SQLite 3.51.2) in sqlcipher legacy=4 mode"

func registerCipherDriver(name string, hexKey string, extra []string) {
	// As with mutecomm, the key must be applied inside the driver's Open
	// (DSN params), before the driver's own schema-touching pragmas.
	pragmas := extra
	currentHexKey = hexKey
	sql.Register(name, &sqlite3.SQLiteDriver{
		ConnectHook: func(c *sqlite3.SQLiteConn) error {
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
	return "?_cipher=sqlcipher&_legacy=4&_key=" + url.QueryEscape("x'"+currentHexKey+"'")
}

const cipherVersionSQL = "SELECT sqlite3mc_version()"

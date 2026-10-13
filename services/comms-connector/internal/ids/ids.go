// Package ids validates the identifiers that cross the connector boundary.
// A connection ref becomes a directory name and a URL path segment, so it is
// checked before it reaches either.
package ids

import "regexp"

// Connection refs are ServiceConnection public ids as Rails mints them:
// "svc_" and the row id. The alphabet cannot traverse a path.
var connRef = regexp.MustCompile(`^svc_[1-9][0-9]{0,18}$`)

// Command ids are SecureRandom.hex(16) on the Rails side.
var commandID = regexp.MustCompile(`^[0-9a-f]{32}$`)

func ValidConnectionRef(s string) bool { return connRef.MatchString(s) }
func ValidCommandID(s string) bool     { return commandID.MatchString(s) }

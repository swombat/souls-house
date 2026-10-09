// Package ids validates the opaque identifiers that cross the connector
// boundary. Every identifier that reaches a file path, a URL path or the
// access log goes through one of these checks first.
package ids

import "regexp"

var (
	// Connection refs become directory names under the data dir, so the
	// alphabet excludes '.', '/' and everything else that could traverse.
	connRef = regexp.MustCompile(`^[A-Za-z0-9_-]{8,64}$`)
	// Chat IDs exposed by the API are connector-assigned opaque IDs, never JIDs.
	chatID = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
	// Ticket IDs are placed in the consume URL path.
	ticketID = regexp.MustCompile(`^[A-Za-z0-9_-]{8,128}$`)
	// Principal, API key, grant and run IDs as minted by Rails.
	opaque = regexp.MustCompile(`^[A-Za-z0-9_.:/-]{1,128}$`)
)

func ValidConnectionRef(s string) bool { return connRef.MatchString(s) }
func ValidChatID(s string) bool        { return chatID.MatchString(s) }
func ValidTicketID(s string) bool      { return ticketID.MatchString(s) }
func ValidOpaque(s string) bool        { return opaque.MatchString(s) }

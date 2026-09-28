# A one-use, short-lived credential for opening the native app's cable
# connection (issue #94 B, step 6). The device asks for one with its bearer
# token and offers it as a Sec-WebSocket-Protocol entry, so the value never
# sits in a URL, a query string or a proxy's access log. Only its SHA-256
# digest is stored.
class AppCableTicket < ApplicationRecord

  LIFETIME = 60.seconds
  PROTOCOL_PREFIX = "souls-house.ticket.".freeze

  belongs_to :app_session

  class << self

    # Returns [value, ticket]. The value exists only in the response.
    def issue!(app_session)
      where(app_session: app_session).where(expires_at: ..Time.current).delete_all
      value = SecureRandom.urlsafe_base64(32)
      [ value, create!(app_session: app_session, token_digest: digest(value), expires_at: LIFETIME.from_now) ]
    end

    # Consumes the ticket in one statement and returns its AppSession, or nil
    # when the ticket is unknown, spent, expired or its session is revoked.
    # FOR SHARE on the session row makes redemption and AppSession#revoke!
    # (which holds FOR UPDATE) take turns, so a ticket can't be spent against
    # a session whose revocation has already committed.
    def redeem(value)
      return if value.blank?

      now = Time.current
      session_id = connection.select_value(sanitize_sql([ <<~SQL, now, digest(value), now ]))
        UPDATE app_cable_tickets SET consumed_at = ?
        WHERE token_digest = ? AND consumed_at IS NULL AND expires_at > ?
          AND app_session_id IN (
            SELECT id FROM app_sessions WHERE id = app_cable_tickets.app_session_id AND revoked_at IS NULL FOR SHARE
          )
        RETURNING app_session_id
      SQL
      AppSession.live.find_by(id: session_id) if session_id
    end

    def digest(value)
      Digest::SHA256.hexdigest(value)
    end

  end

end

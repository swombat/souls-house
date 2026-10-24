module ApplicationCable
  class Connection < ActionCable::Connection::Base

    # current_app_session is nil for the web's cookie connections and set for
    # the native app's ticket connections (issue #94 B, step 6).
    identified_by :current_user, :current_app_session, :current_companion_device

    def connect
      info "🔌 ActionCable connection attempt"
      if companion_ticket_offered?
        self.current_companion_device = CompanionCableTicket.redeem(offered_companion_ticket)
        reject_unauthorized_connection unless current_companion_device
        return
      elsif ticket_offered?
        self.current_app_session = find_ticketed_app_session
        self.current_user = current_app_session.user
      else
        self.current_user = find_verified_user
      end
      info "🔌 ✅ Connected as #{current_user.email_address}"
    end

    private

    def offered_companion_ticket
      request.headers["Sec-WebSocket-Protocol"].to_s.split(",").map(&:strip)
        .find { |protocol| protocol.start_with?(CompanionCableTicket::PROTOCOL_PREFIX) }
        &.delete_prefix(CompanionCableTicket::PROTOCOL_PREFIX)
    end

    def companion_ticket_offered?
      !offered_companion_ticket.nil?
    end

    def find_verified_user
      session_id = cookies.signed[LocalInstance.current.cookie(:session_id)]
      info "🔌 Session ID from cookie: #{session_id.inspect}"

      if session_id && (session = Session.find_by(id: session_id))
        info "🔌 Found session for user: #{session.user.email_address}"
        session.user
      else
        info "🔌 ❌ No valid session found, rejecting connection"
        reject_unauthorized_connection
      end
    end

    # A connection that offers a ticket is authenticated by the ticket alone:
    # a bad ticket is rejected and never falls back to the cookie.
    def find_ticketed_app_session
      AppCableTicket.redeem(offered_ticket) || begin
        info "🔌 ❌ Cable ticket refused, rejecting connection"
        reject_unauthorized_connection
      end
    end

    # Offering the ticket protocol at all selects ticket authentication, even
    # with an empty value: an empty ticket is refused, never read as a cookie
    # connection.
    def ticket_offered?
      !offered_ticket.nil?
    end

    def offered_ticket
      offered = request.headers["Sec-WebSocket-Protocol"].to_s.split(",").map(&:strip)
      offered.find { |protocol| protocol.start_with?(AppCableTicket::PROTOCOL_PREFIX) }&.delete_prefix(AppCableTicket::PROTOCOL_PREFIX)
    end

    # The origin check protects cookie connections from cross-site pages. A
    # ticket connection carries no cookie authority (see above), and a native
    # client sends no browser Origin, so the check doesn't apply to it.
    def allow_request_origin?
      companion_ticket_offered? || ticket_offered? || super
    end

  end
end

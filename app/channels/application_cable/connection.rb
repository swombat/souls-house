module ApplicationCable
  class Connection < ActionCable::Connection::Base

    identified_by :current_user

    def connect
      info "🔌 ActionCable connection attempt"
      self.current_user = find_verified_user
      info "🔌 ✅ Connected as #{current_user.email_address}"
    end

    private

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

  end
end

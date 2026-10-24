require "openssl"

module Services
  # A person's Telegram user account through the comms connector (proposal
  # 2026-10-11). The Telegram session lives in the connector, never in Rails:
  # credential_payload holds only the per-connection callback secret (and its
  # version) the connector signs events with.
  #
  # Login is QR, or the phone number and the code Telegram sends (for a
  # phone, which cannot scan its own screen), then the account's two-step
  # password if it has one. Each attempt has a login generation: starting or
  # cancelling moves it on, and a command or event for an older generation is
  # refused on both sides, so a delayed or replayed start never reopens a
  # cancelled login.
  class TelegramAdapter

    class Error < Services::AdapterError; end
    # The sign-in moved on (restarted, cancelled or finished) since the page
    # was drawn.
    class StaleAttempt < Error; end

    attr_reader :definition

    def initialize(definition)
      @definition = definition
    end

    def connection_attributes(credentials:, user:)
      secret = SecureRandom.hex(32)
      {
        external_subject_id: nil,
        external_identity: nil,
        label: definition.name,
        status: "pairing",
        credential_kind: "connector",
        credential_fingerprint: credential_fingerprint(secret),
        credential_payload: { "callback_secret" => secret, "callback_secret_version" => 1 },
        credential_metadata: {
          "credential_strategy" => definition.credential_strategy,
          "authority_summary" => "Residents you enable can read the chats this account syncs and search it. Nothing can be sent."
        }
      }
    end

    # Connect, and Restart after an expiry, failure or Telegram-side logout:
    # a new generation, taken under the row lock.
    def start_pairing(connection)
      generation = connection.begin_login_attempt!
      raise StaleAttempt, "This connection is not waiting to sign in" if generation.nil?

      CommsConnector.telegram_command(connection, "start_login", generation:,
                                                                 callback_secret: connection.credential_payload_hash["callback_secret"],
                                                                 callback_secret_version: connection.credential_payload_hash["callback_secret_version"].to_i)
    rescue CommsConnector::Error, SystemCallError, Timeout::Error, IOError, OpenSSL::SSL::SSLError => e
      Rails.logger.warn("Comms start_login failed for service connection #{connection.id}: #{e.class}")
      raise Error, "Could not reach the Telegram connector. Try again, or disconnect this connection."
    end

    # Returns :not_pairing when there was nothing to cancel. The local state
    # is already "cancelled" before the connector is told.
    def cancel_login(connection)
      generation = connection.cancel_login_attempt!
      return :not_pairing if generation.nil?

      CommsConnector.telegram_command(connection, "cancel_login", generation:)
    rescue CommsConnector::Error, SystemCallError, Timeout::Error, IOError, OpenSSL::SSL::SSLError => e
      Rails.logger.warn("Comms cancel_login failed for service connection #{connection.id}: #{e.class}")
      :failed
    end

    # The two-step password goes straight through, inside the owner's
    # request: never stored, never queued, never logged. The connector does
    # SRP and drops it. It belongs to the attempt the owner's page showed:
    # if that attempt has moved on, nothing is sent. Returns the connector's
    # outcome hash.
    def submit_password(connection, password, generation:)
      connection.reload
      unless connection.status == "pairing" && connection.login_state["step"] == "password" &&
             generation == connection.login_generation
        raise StaleAttempt, "This sign-in has moved on. Use the current page."
      end

      CommsConnector.telegram_command(connection, "submit_password", generation:, password:)
    rescue StaleAttempt
      raise
    rescue CommsConnector::Error, SystemCallError, Timeout::Error, IOError, OpenSSL::SSL::SSLError => e
      Rails.logger.warn("Comms submit_password failed for service connection #{connection.id}: #{e.class}")
      raise Error, "Could not reach the Telegram connector. Try again."
    end

    # The phone path: Telegram sends a code to the account's app (or by
    # SMS). The number goes straight through inside the owner's request, like
    # the password: never stored, queued or logged. Only for the attempt the
    # owner's page showed, while it is signing in and no password is wanted.
    # On code_sent the code step is recorded at once (the connector's
    # login.code_sent event says the same); if the attempt ended meanwhile
    # (it expired while Telegram answered), the late answer is refused, not
    # passed on. Returns the connector's outcome.
    def request_code(connection, phone, generation:)
      connection.reload
      unless connection.status == "pairing" && connection.login_state["step"] != "password" &&
             connection.login_state["error"].blank? && generation == connection.login_generation
        raise StaleAttempt, "This sign-in has moved on. Use the current page."
      end

      result = CommsConnector.telegram_command(connection, "request_code", generation:, phone:)
      if result.is_a?(Hash) && result["outcome"] == "code_sent" && (step = CommsEvents.code_step(result)) &&
         !connection.record_login_code_step!(generation, step)
        raise StaleAttempt, "This sign-in has moved on. Use the current page."
      end
      result
    rescue StaleAttempt
      raise
    rescue CommsConnector::Error, SystemCallError, Timeout::Error, IOError, OpenSSL::SSL::SSLError => e
      Rails.logger.warn("Comms request_code failed for service connection #{connection.id}: #{e.class}")
      raise Error, "Could not reach the Telegram connector. Try again."
    end

    # The code Telegram sent, for the attempt that asked for it: forwarded
    # and kept nowhere. Returns the connector's outcome.
    def submit_code(connection, code, generation:)
      connection.reload
      unless connection.status == "pairing" && connection.login_state["step"] == "code" &&
             generation == connection.login_generation
        raise StaleAttempt, "This sign-in has moved on. Use the current page."
      end

      CommsConnector.telegram_command(connection, "submit_code", generation:, code:)
    rescue StaleAttempt
      raise
    rescue CommsConnector::Error, SystemCallError, Timeout::Error, IOError, OpenSSL::SSL::SSLError => e
      Rails.logger.warn("Comms submit_code failed for service connection #{connection.id}: #{e.class}")
      raise Error, "Could not reach the Telegram connector. Try again."
    end

    def search(connection, query:, chat: nil, limit: nil, scope: "synced")
      CommsConnector.telegram_command(connection, "search", query:, chat:, limit:, scope:)
    end

    # Disconnecting logs out at Telegram (auth.logOut), so the session leaves
    # the account's Active Sessions, then the connector deletes it. A failure
    # is logged, not raised; the local secret is erased either way.
    def revoke(connection)
      CommsConnector.telegram_command(connection, "logout")
    rescue StandardError => e
      Rails.logger.warn("Comms logout failed for service connection #{connection.id}: #{e.class}")
    end

    private

    def credential_fingerprint(secret)
      key = Rails.application.key_generator.generate_key("service-credential-fingerprint", 32)
      OpenSSL::HMAC.hexdigest("SHA256", key, secret)
    end

  end
end

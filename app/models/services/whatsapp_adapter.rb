require "openssl"

module Services
  # WhatsApp through the comms connector. The WhatsApp session lives in the
  # connector, never in Rails: credential_payload holds only the per-connection
  # callback secret (and its version) the connector signs its events with. The
  # secret reaches the connector once, inside the signed start_pairing command
  # over mutual TLS (CommsConnector). A connection starts
  # in "pairing" and becomes "connected" when the connector reports it.
  class WhatsappAdapter

    class Error < Services::AdapterError; end

    attr_reader :definition

    def initialize(definition)
      @definition = definition
    end

    def connection_attributes(credentials:, user:)
      secret = SecureRandom.hex(32)
      {
        external_subject_id: nil,
        external_identity: nil,
        label: nil,
        status: "pairing",
        credential_kind: "connector",
        credential_fingerprint: credential_fingerprint(secret),
        credential_payload: { "callback_secret" => secret, "callback_secret_version" => 1 },
        credential_metadata: {
          "credential_strategy" => definition.credential_strategy,
          "authority_summary" => "Residents you enable can read the chats and messages this linked device receives. Nothing can be sent."
        }
      }
    end

    def start_pairing(connection)
      CommsConnector.start_pairing(connection)
    rescue CommsConnector::Error, SystemCallError, Timeout::Error, IOError, OpenSSL::SSL::SSLError => e
      Rails.logger.warn("Comms start_pairing failed for service connection #{connection.id}: #{e.class}")
      raise Error, "Could not reach the WhatsApp connector. Disconnect this connection and try again."
    end

    # The phone number pairing (Accounts::ServiceConnectionPairingsController#phone).
    # Only the error's class is logged: never the number.
    # :superseded when the connector already took a newer request (another
    # tab's, sent after this one was recorded but arriving first).
    def pair_phone(connection, phone_number, attempt:, request:, seq:)
      CommsConnector.pair_phone(connection, phone_number, attempt:, request:, seq:)
    rescue CommsConnector::StaleRequest
      :superseded
    rescue CommsConnector::Error, SystemCallError, Timeout::Error, IOError, OpenSSL::SSL::SSLError => e
      Rails.logger.warn("Comms pair_phone failed for service connection #{connection.id}: #{e.class}")
      raise Error, "Could not reach the WhatsApp connector. Try again in a moment."
    end

    # Disconnecting unpairs: the connector logs the linked device out and
    # deletes its session store. The local secret is erased either way, so
    # the connector can no longer write to this connection; but until the
    # connector has unpaired, its device may still be receiving. So a failure
    # does not stop the disconnect: it is recorded on the connection (shown
    # to the owner, and keeping the revoked connection), and CommsUnpairJob
    # retries until the connector confirms.
    def revoke(connection)
      CommsConnector.unpair!(connection)
    rescue StandardError => e
      Rails.logger.warn("Comms unpair failed for service connection #{connection.id}: #{e.class}")
      connection.record_unpair_failure!(e)
    end

    # Sending (CommsSending). The three things a provider supplies.

    # A WhatsApp message id in the shape of whatsmeow's package-level
    # GenerateMessageID (go.mau.fi/whatsmeow v0.0.0-20261007111105-c386243a72ba,
    # send.go): "3EB0" followed by 8 random bytes as upper-case hex, 20
    # characters. This is the shape the connector accepts for send_text
    # (exactly this pattern) and passes unchanged as SendRequestExtra{ID: ...}.
    # (Client.GenerateMessageID, at the same version, hashes time, own JID and
    # random bytes into "3EB0" + 18 hex; WhatsApp accepts both.)
    SEND_MESSAGE_ID_FORMAT = /\A3EB0[0-9A-F]{16}\z/

    def new_send_message_id
      "3EB0#{SecureRandom.hex(8).upcase}"
    end

    # The session a send is bound to: the pairing attempt, which
    # start_pairing hands the connector and every connector event carries.
    def send_generation(connection)
      connection.pairing_attempt
    end

    def send_text(send)
      CommsConnector.send_text(send)
    end

    # Who our own messages are from, as the connector stores them: the
    # owner's phone-number JID (identity user_id is its user part) and push
    # name.
    def own_sender(connection)
      user = connection.external_subject_id.to_s
      {
        "sender_id" => (user.include?("@") ? user : "#{user}@s.whatsapp.net" if user.present?),
        "sender_name" => connection.external_identity
      }
    end

    private

    def credential_fingerprint(secret)
      key = Rails.application.key_generator.generate_key("service-credential-fingerprint", 32)
      OpenSSL::HMAC.hexdigest("SHA256", key, secret)
    end

  end
end

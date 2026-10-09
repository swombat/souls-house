require "openssl"

module Services
  # WhatsApp through the comms connector. The WhatsApp session lives in the
  # connector, never in Rails: credential_payload holds only the per-connection
  # callback secret the connector signs its events with. A connection starts
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
        label: definition.name,
        status: "pairing",
        credential_kind: "connector",
        credential_fingerprint: credential_fingerprint(secret),
        credential_payload: { "callback_secret" => secret },
        credential_metadata: {
          "credential_strategy" => definition.credential_strategy,
          "authority_summary" => "Residents you enable can read the chats and messages this linked device receives. Only residents you separately allow can send, as you, into existing chats."
        }
      }
    end

    def start_pairing(connection)
      CommsConnector.start_pairing(connection)
    rescue CommsConnector::Error, SystemCallError, Timeout::Error, IOError => e
      Rails.logger.warn("Comms start_pairing failed for service connection #{connection.id}: #{e.class}")
      raise Error, "Could not reach the WhatsApp connector. Disconnect this connection and try again."
    end

    # Disconnecting unpairs: the connector logs the linked device out and
    # deletes its session store. A failure is logged, not raised, as for
    # Oura's revocation; the local secret is erased either way, so the
    # connector can no longer write to this connection.
    def revoke(connection)
      CommsConnector.unpair(connection)
    rescue StandardError => e
      Rails.logger.warn("Comms unpair failed for service connection #{connection.id}: #{e.class}")
    end

    private

    def credential_fingerprint(secret)
      key = Rails.application.key_generator.generate_key("service-credential-fingerprint", 32)
      OpenSSL::HMAC.hexdigest("SHA256", key, secret)
    end

  end
end

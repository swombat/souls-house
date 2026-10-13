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
        label: definition.name,
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

    private

    def credential_fingerprint(secret)
      key = Rails.application.key_generator.generate_key("service-credential-fingerprint", 32)
      OpenSSL::HMAC.hexdigest("SHA256", key, secret)
    end

  end
end

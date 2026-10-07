require "openssl"

module Services
  class TailscaleAdapter

    AUTH_KEY_PATTERN = /\Atskey-auth-[A-Za-z0-9_-]+\z/
    ALIAS_PATTERN = /\A[a-z0-9][a-z0-9_-]{0,31}\z/
    USER_PATTERN = /\A[a-z_][a-z0-9_.-]{0,31}\z/i
    MACHINE_PATTERN = /\A[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?\z/
    MAX_HOSTS = 16

    class Error < Services::AdapterError; end

    attr_reader :definition

    def initialize(definition)
      @definition = definition
    end

    SIGN_IN_FINGERPRINT_SOURCE = "tailscale:sign-in"

    # Normally there is nothing to check here: each resident's node joins when
    # a person signs in to Tailscale from that resident's integrations tab, so
    # the node belongs to whoever signed in. One such connection per account.
    #
    # The catalog declares no fields, so the connect controller passes nothing
    # here and no new keyed connection can be made. The key/hosts branch below
    # is kept so connections made with a key before sign-in existed keep
    # describing themselves correctly; the runtime still joins those with
    # their key. There is no network call either way.
    def connection_attributes(credentials:, user:)
      auth_key = credentials["auth_key"].to_s.strip
      if auth_key.present? && !auth_key.match?(AUTH_KEY_PATTERN)
        raise Error, "Use a Tailscale auth key (it starts with tskey-auth-)"
      end

      hosts = parse_hosts(credentials["hosts"])
      label = hosts.any? ? "Tailnet: #{hosts.map { |h| h['alias'] }.join(', ')}" : "Tailnet"

      {
        external_subject_id: nil,
        external_identity: nil,
        label: label,
        credential_kind: auth_key.present? ? "token" : "none",
        credential_fingerprint: credential_fingerprint(auth_key.presence || SIGN_IN_FINGERPRINT_SOURCE),
        credential_payload: auth_key.present? ? { "auth_key" => auth_key } : {},
        credential_metadata: {
          "credential_strategy" => definition.credential_strategy,
          "join" => auth_key.present? ? "auth_key" : "sign_in",
          "hosts" => hosts,
          "authority_summary" => if auth_key.present?
                                   "Joins residents to the tailnet as tagged nodes. The tailnet policy for the key's tag, " \
                                     "and the accounts that accept each resident's SSH key, are the actual authority."
                                 else
                                   "Each resident joins the tailnet of whoever signs in for it, and can reach every machine " \
                                     "there. The accounts that accept the resident's SSH key decide what it can do on arrival."
                                 end
        }
      }
    end

    def revoke(_connection)
      # Auth keys are revoked in the Tailscale admin console. Removing the
      # connection drops the key from residents' manifests, and the runtime
      # logs a resident's node out at the next boot without the grant.
      true
    end

    private

    def parse_hosts(value)
      entries = value.to_s.split(/[,\n]/).map(&:strip).reject(&:blank?)
      raise Error, "At most #{MAX_HOSTS} hosts" if entries.size > MAX_HOSTS

      hosts = entries.map { |entry| parse_host(entry) }
      duplicate = hosts.group_by { |h| h["alias"] }.find { |_, group| group.size > 1 }&.first
      raise Error, "Host alias #{duplicate} is listed twice" if duplicate

      hosts
    end

    def parse_host(entry)
      match = entry.match(/\A([^=\s]+)\s*=\s*(?:([^@\s]+)@)?(\S+)\z/)
      raise Error, "Host entries use alias=user@machine (got #{entry.inspect})" unless match

      host_alias, user, machine = match.captures
      host_alias = host_alias.downcase
      raise Error, "Host alias #{host_alias.inspect} must be lowercase letters, digits, - or _" unless host_alias.match?(ALIAS_PATTERN)
      raise Error, "SSH user #{user.inspect} is not a valid user name" if user && !user.match?(USER_PATTERN)
      raise Error, "Machine #{machine.inspect} is not a valid tailnet name or address" unless machine.match?(MACHINE_PATTERN)

      { "alias" => host_alias, "user" => user, "machine" => machine }.compact
    end

    def credential_fingerprint(auth_key)
      key = Rails.application.key_generator.generate_key("service-credential-fingerprint", 32)
      OpenSSL::HMAC.hexdigest("SHA256", key, auth_key)
    end

  end
end

require "net/http"
require "json"
require "openssl"

module Services
  class GithubTokenAdapter

    API_ROOT = "https://api.github.com"
    REPOSITORY_PATTERN = %r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}

    class Error < Services::AdapterError; end

    attr_reader :definition

    def initialize(definition)
      @definition = definition
    end

    def connection_attributes(credentials:, user:)
      token = credentials["token"].to_s.strip
      repository_name = credentials["repository"].to_s.strip
      @oauth_scopes = nil
      raise Error, "GitHub token is required" if token.blank?
      raise Error, "Repository must use the owner/repository format" unless repository_name.match?(REPOSITORY_PATTERN)

      identity = get_json("/user", token)
      repository = get_json("/repos/#{repository_name}", token)
      full_name = repository.fetch("full_name")

      {
        external_subject_id: identity.fetch("id").to_s,
        external_identity: identity.fetch("login"),
        label: full_name,
        credential_kind: "token",
        credential_fingerprint: credential_fingerprint(token),
        credential_payload: {
          "token" => token
        },
        credential_metadata: {
          "credential_strategy" => definition.credential_strategy,
          "authority_fingerprint" => credential_fingerprint(token),
          "repository" => full_name,
          "repository_id" => repository.fetch("id").to_s,
          "clone_url" => repository["clone_url"],
          "default_branch" => repository["default_branch"],
          "private" => repository["private"],
          **self.class.authority_metadata(token, scopes: @oauth_scopes),
          "authority_summary" => "Direct GitHub access intended for #{full_name}. Format and repository access do not prove the token is restricted to this repository; its GitHub permissions are the actual authority."
        }.compact
      }
    rescue KeyError
      raise Error, "GitHub returned incomplete identity or repository information"
    end

    def revoke(_connection)
      # GitHub personal access tokens cannot be revoked through the ordinary
      # REST API by the application storing them. The user revokes the token
      # from GitHub; souls.house removes its encrypted local copy.
      true
    end

    def self.authority_metadata(token, scopes: nil)
      kind = if token.to_s.start_with?("github_pat_")
        "fine_grained"
      elsif token.to_s.start_with?("ghp_")
        "classic"
      else
        "unknown"
      end
      {
        "token_kind" => kind,
        "oauth_scopes" => scopes,
        "authority_source" => scopes.nil? ? (kind == "unknown" ? "unknown" : "token_format") : "X-OAuth-Scopes",
        "authority_warnings" => [ "Token format is not proof of least privilege. Exact fine-grained permissions are not reported by these endpoints." ]
      }
    end

    def self.fingerprint(token)
      key = Rails.application.key_generator.generate_key("service-credential-fingerprint", 32)
      OpenSSL::HMAC.hexdigest("SHA256", key, token)
    end

    private

    def get_json(path, token)
      uri = URI("#{API_ROOT}#{path}")
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/vnd.github+json"
      request["Authorization"] = "Bearer #{token}"
      request["X-GitHub-Api-Version"] = "2022-11-28"
      request["User-Agent"] = "souls.house service connection"
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
      header = response["X-OAuth-Scopes"]
      @oauth_scopes = header.split(",").map(&:strip).reject(&:blank?).uniq if path == "/user" && !header.nil?

      case response
      when Net::HTTPSuccess
        JSON.parse(response.body)
      when Net::HTTPUnauthorized
        raise Error, "GitHub rejected this token"
      when Net::HTTPForbidden
        raise Error, "GitHub did not allow this token to access #{path == '/user' ? 'the user identity' : 'that repository'}"
      when Net::HTTPNotFound
        raise Error, "GitHub could not find that repository with this token"
      else
        raise Error, "GitHub validation failed (#{response.code})"
      end
    rescue JSON::ParserError
      raise Error, "GitHub returned invalid JSON"
    end

    def credential_fingerprint(token)
      self.class.fingerprint(token)
    end

  end
end

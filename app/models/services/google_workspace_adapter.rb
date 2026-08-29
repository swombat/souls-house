require "net/http"
require "json"
require "base64"
require "digest"

module Services
  class GoogleWorkspaceAdapter

    AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth"
    TOKEN_URL = "https://oauth2.googleapis.com/token"
    IDENTITY_URL = "https://openidconnect.googleapis.com/v1/userinfo"
    REVOKE_URL = "https://oauth2.googleapis.com/revoke"

    class Error < Services::AdapterError; end

    attr_reader :definition

    def initialize(definition)
      @definition = definition
    end

    def authorization_url(attempt, state:, redirect_uri:)
      challenge = Base64.urlsafe_encode64(
        Digest::SHA256.digest(attempt.pkce_verifier),
        padding: false
      )
      "#{AUTHORIZE_URL}?#{{
        response_type: "code",
        client_id: client_id,
        redirect_uri: redirect_uri,
        access_type: "offline",
        prompt: "consent",
        scope: attempt.requested_scopes.join(" "),
        state: state,
        code_challenge: challenge,
        code_challenge_method: "S256"
      }.to_query}"
    end

    def exchange_code(code:, attempt:, redirect_uri:)
      data = token_request(
        grant_type: "authorization_code",
        code: code,
        redirect_uri: redirect_uri,
        code_verifier: attempt.pkce_verifier
      )
      identity = fetch_identity(data.fetch("access_token"))

      {
        external_subject_id: identity.fetch("sub"),
        external_identity: identity["email"].presence || identity["name"],
        credential_kind: "oauth2",
        credential_payload: credential_payload(data),
        credential_metadata: credential_metadata(data, attempt)
      }
    end

    def effective_authority(scopes, requested_selection:)
      requested = definition.normalize_authority_selection(requested_selection.presence || {})
      if scopes.nil?
        return {
          "selection" => apply_drive_floor(requested),
          "warnings" => [ "Google did not confirm the granted scopes." ]
        }
      end

      granted = Array(scopes)
      drive = scope_level(granted,
        read: %w[https://www.googleapis.com/auth/drive.readonly],
        write: %w[https://www.googleapis.com/auth/drive])
      selection = {
        "drive" => drive,
        "docs" => scope_level(granted,
          read: %w[https://www.googleapis.com/auth/documents.readonly],
          write: %w[https://www.googleapis.com/auth/documents]),
        "sheets" => scope_level(granted,
          read: %w[https://www.googleapis.com/auth/spreadsheets.readonly],
          write: %w[https://www.googleapis.com/auth/spreadsheets]),
        "slides" => scope_level(granted,
          read: %w[https://www.googleapis.com/auth/presentations.readonly],
          write: %w[https://www.googleapis.com/auth/presentations]),
        "calendar" => calendar_level(granted),
        "gmail" => gmail_level(granted),
        "meet" => scope_level(granted,
          read: %w[https://www.googleapis.com/auth/meetings.space.readonly],
          write: %w[https://www.googleapis.com/auth/meetings.space.settings])
      }
      effective = apply_drive_floor(selection)
      missing = effective.select { |group, level| rank(level) < rank(requested.fetch(group)) }.keys
      warnings = missing.any? ? [ "Google did not grant all requested access: #{missing.map(&:humanize).join(', ')}." ] : []
      { "selection" => effective, "warnings" => warnings }
    end

    def current_access_token(connection)
      connection.with_lock do
        connection.reload
        payload = connection.credential_payload_hash
        return payload.fetch("access_token") if token_fresh?(payload)

        refresh_token = payload["refresh_token"].presence ||
          raise(Error, "Google Workspace refresh token is unavailable; reconnect Google Workspace")
        data = token_request(grant_type: "refresh_token", refresh_token: refresh_token)
        refreshed_payload = credential_payload(data, previous_refresh_token: refresh_token)
        connection.replace_credential_payload_without_reconciliation!(refreshed_payload)
        refreshed_payload.fetch("access_token")
      end
    end

    def revoke(connection)
      revoke!(connection)
    rescue StandardError => e
      Rails.logger.warn("Google Workspace token revocation failed for service connection #{connection.id}: #{e.class}")
    end

    def revoke!(connection)
      payload = connection.credential_payload_hash
      token = payload["refresh_token"].presence || payload["access_token"]
      return if token.blank?

      response = Net::HTTP.post_form(URI(REVOKE_URL), token: token)
      raise Error, "Google Workspace credential revocation failed (#{response.code})" unless response.is_a?(Net::HTTPSuccess)
    end

    private

    def credential_metadata(data, attempt)
      granted_scopes = data.key?("scope") ? data["scope"].to_s.split : nil
      requested_authority = if attempt.authority_selection.present?
        definition.normalize_authority_selection(attempt.authority_selection)
      else
        effective_authority(attempt.requested_scopes, requested_selection: definition.default_authority_selection)
          .fetch("selection")
      end
      effective = effective_authority(granted_scopes, requested_selection: requested_authority)
      {
        "requested_authority" => requested_authority,
        "granted_scopes" => granted_scopes,
        "effective_authority" => effective.fetch("selection"),
        "authority_warnings" => effective.fetch("warnings"),
        "credential_strategy" => definition.credential_strategy
      }
    end

    def apply_drive_floor(selection)
      result = selection.stringify_keys
      drive_rank = rank(result.fetch("drive"))
      %w[docs sheets slides].each do |group|
        result[group] = level_for_rank([ rank(result.fetch(group)), drive_rank ].max)
      end
      result
    end

    def scope_level(granted, read:, write:)
      return "write" if (granted & write).any?
      return "read" if (granted & read).any?
      "none"
    end

    def gmail_level(granted)
      return "write" if granted.include?("https://mail.google.com/") ||
        (granted.include?("https://www.googleapis.com/auth/gmail.modify") &&
          granted.include?("https://www.googleapis.com/auth/gmail.send"))
      return "read" if (granted & %w[
        https://www.googleapis.com/auth/gmail.readonly
        https://www.googleapis.com/auth/gmail.modify
      ]).any?
      "none"
    end

    def calendar_level(granted)
      return "write" if granted.include?("https://www.googleapis.com/auth/calendar") ||
        (granted.include?("https://www.googleapis.com/auth/calendar.readonly") &&
          granted.include?("https://www.googleapis.com/auth/calendar.events"))
      return "read" if granted.include?("https://www.googleapis.com/auth/calendar.readonly")
      "none"
    end

    def rank(level)
      { "none" => 0, "read" => 1, "write" => 2 }.fetch(level.to_s)
    end

    def level_for_rank(value)
      %w[none read write].fetch(value)
    end

    def token_request(params)
      response = Net::HTTP.post_form(URI(TOKEN_URL), params.merge(
        client_id: client_id,
        client_secret: client_secret
      ))
      parse_success(response, "Google OAuth token exchange")
    end

    def fetch_identity(access_token)
      uri = URI(IDENTITY_URL)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{access_token}"
      parse_success(
        Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) },
        "Google identity lookup"
      )
    end

    def credential_payload(data, previous_refresh_token: nil)
      {
        "access_token" => data.fetch("access_token"),
        "refresh_token" => data["refresh_token"].presence || previous_refresh_token,
        "expires_at" => data["expires_in"].to_i.seconds.from_now.utc.iso8601
      }.compact
    end

    def token_fresh?(payload)
      expires_at = Time.iso8601(payload["expires_at"].to_s)
      payload["access_token"].present? && expires_at > 1.minute.from_now
    rescue ArgumentError
      false
    end

    def parse_success(response, label)
      raise Error, "#{label} failed (#{response.code})" unless response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body)
    rescue JSON::ParserError
      raise Error, "#{label} returned invalid JSON"
    end

    def client_id
      Rails.application.credentials.dig(:google_workspace, :client_id) ||
        ENV["GOOGLE_WORKSPACE_CLIENT_ID"] ||
        raise(ArgumentError, "Google Workspace client_id is not configured")
    end

    def client_secret
      Rails.application.credentials.dig(:google_workspace, :client_secret) ||
        ENV["GOOGLE_WORKSPACE_CLIENT_SECRET"] ||
        raise(ArgumentError, "Google Workspace client_secret is not configured")
    end

  end
end

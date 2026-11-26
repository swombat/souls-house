module Visits
  # Parses a pasted visitor invitation URL into a normalized origin and token.
  # Accepts URLs such as:
  #   https://other.example/api/v1/visit/invitations/<token>
  #   https://other.example/visit/invitations/<token>
  #   https://other.example/invitations/<token>
  class InvitationLink

    class InvalidError < StandardError; end

    Parsed = Data.define(:origin, :token)

    TOKEN_PATTERN = /\A[A-Za-z0-9._-]{8,256}\z/

    def self.parse(raw_url = nil, origin: nil, token: nil)
      if raw_url.present?
        parse_url(raw_url)
      elsif origin.present? && token.present?
        Parsed.new(
          origin: normalize_origin(origin),
          token: validate_token(token)
        )
      else
        raise InvalidError, "Paste an invitation link from the other house"
      end
    end

    def self.normalize_origin(raw)
      uri = URI.parse(raw.to_s.strip)
      unless uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.blank?
        raise InvalidError, "Invitation link must start with https:// or http://"
      end

      default_port = (uri.scheme == "https" && uri.port == 443) || (uri.scheme == "http" && uri.port == 80)
      port_part = default_port ? "" : ":#{uri.port}"
      host_part = uri.host.include?(":") ? "[#{uri.host}]" : uri.host
      "#{uri.scheme}://#{host_part}#{port_part}"
    rescue URI::InvalidURIError
      raise InvalidError, "That doesn't look like a valid invitation link"
    end

    def self.parse_url(raw_url)
      uri = URI.parse(raw_url.to_s.strip)
      unless uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.blank?
        raise InvalidError, "Invitation link must start with https:// or http://"
      end

      segments = uri.path.to_s.split("/").reject(&:empty?)
      token = segments.last
      unless segments.length >= 2 && segments[-2] == "invitations" && token.present?
        raise InvalidError, "Invitation link must end with /invitations/<token>"
      end

      Parsed.new(
        origin: normalize_origin("#{uri.scheme}://#{uri.host}:#{uri.port}"),
        token: validate_token(token)
      )
    rescue URI::InvalidURIError
      raise InvalidError, "That doesn't look like a valid invitation link"
    end

    def self.validate_token(token)
      cleaned = token.to_s.strip
      raise InvalidError, "Invitation token is missing or malformed" unless cleaned.match?(TOKEN_PATTERN)

      cleaned
    end

  end
end

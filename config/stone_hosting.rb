# Loaded before middleware construction, not a reloadable application constant.
require "public_suffix"

module StoneHosting

  class InvalidConfiguration < StandardError; end

  def self.domain
    ENV["SOULSHOUSE_STONES_DOMAIN"].to_s.strip.downcase.presence
  end

  def self.validate!
    return unless domain

    unless domain.match?(/\A[a-z0-9]+(?:[.-][a-z0-9]+)*\z/) &&
        PublicSuffix.valid?(domain) && PublicSuffix.domain(domain) == domain
      raise InvalidConfiguration, "SOULSHOUSE_STONES_DOMAIN must be a separate registrable domain, without scheme or port"
    end
    house = ENV["SOULSHOUSE_DOMAIN"].to_s.downcase
    if house.empty? || !PublicSuffix.valid?(house)
      raise InvalidConfiguration, "Set SOULSHOUSE_DOMAIN before enabling separate stone hosting"
    end
    if PublicSuffix.domain(house) == domain
      raise InvalidConfiguration, "Stones must not share the house's registrable domain"
    end
  end

  def self.content_host?(host)
    domain && (host == domain || host.end_with?(".#{domain}"))
  end

  def self.name(host)
    return unless domain && host.end_with?(".#{domain}")

    label = host.delete_suffix(".#{domain}")
    label if label.match?(/\A[a-z]+-[a-z]+-[a-z]+\z/) && label.bytesize <= 63
  end

  # Runs before cookies, sessions, static files and application routing. A stone
  # hostname must never turn into another entry point to house APIs or assets.
  class Boundary

    def initialize(app)
      @app = app
    end

    def call(env)
      request = ActionDispatch::Request.new(env)
      # Check the actual Host as well as Rails' forwarded-host interpretation.
      # A forged X-Forwarded-Host must not turn a stone request into a house API.
      raw_host = env["HTTP_HOST"].to_s.downcase.split(":").first.to_s.delete_suffix(".")
      forwarded_host = request.host.downcase.delete_suffix(".")
      host = [ raw_host, forwarded_host ].find { |candidate| StoneHosting.content_host?(candidate) }
      unless host
        # Kamal probes /up with an internal target Host. Do not open any other
        # house routes on the stones process, even if its domain is missing.
        if ENV["SOULSHOUSE_STONES_ONLY"] != "1" ||
            (%w[GET HEAD].include?(request.request_method) && request.path == "/up")
          return @app.call(env)
        end
        return not_found
      end

      name = StoneHosting.name(host)
      return not_found unless name && (reading?(request) || writing?(request))

      env["souls_house.stone_name"] = name
      env.delete("HTTP_X_FORWARDED_HOST")
      env.delete("HTTP_FORWARDED")
      env["HTTP_HOST"] = host
      env.delete("HTTP_COOKIE")
      env.delete("HTTP_AUTHORIZATION")
      status, headers, body = @app.call(env)
      headers.delete("set-cookie")
      headers.delete("Set-Cookie")
      [ status, headers, body ]
    end

    private

    def reading?(request)
      %w[GET HEAD].include?(request.request_method) &&
        request.path.match?(%r{\A/(?:revisions/[1-9][0-9]*(?:/content|/data)?)?\z})
    end

    # The one write: a small JSON row from a stone's write link. The key comes
    # in X-Stone-Write-Key (Authorization and cookies are still dropped below),
    # and a custom header means another site can't send it without a CORS
    # preflight, which nothing here answers.
    def writing?(request)
      request.request_method == "POST" && request.path.match?(%r{\A/revisions/[1-9][0-9]*/rows\z}) &&
        request.media_type == "application/json" && request.content_length.to_i.between?(1, WRITE_BODY_LIMIT)
    end

    WRITE_BODY_LIMIT = 16_384

    def not_found
      [ 404, { "content-type" => "text/plain", "cache-control" => "no-store",
               "content-security-policy" => "sandbox; default-src 'none'" }, [ "Stone not found" ] ]
    end

  end

end

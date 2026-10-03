# Thin client for the Hetzner Cloud servers API, for resident placement.
#
# Deliberately small and not wired to anything yet: create, find and delete
# one server. It holds the procurement boundary, so it fails closed:
#
# * no default token; a blank token raises NotConfigured before any request,
#   and requests only ever go to the fixed production API origin
# * server types and locations must be on an explicit allowlist
# * SSH keys are required, so Hetzner never generates a root password;
#   callers only ever receive Server values, which have no field for one
# * a create whose outcome is not known (timeout, dropped connection, 5xx,
#   unreadable or malformed success) raises CreateOutcomeUnknown, which is
#   never retryable here. Retry decisions belong to the durable operation
#   layer that will call this client.
# * labels support discovery, not idempotency: Hetzner will accept two creates
#   with the same labels, and an empty find_by_placement shortly after an
#   unknown create is not proof that no server was bought
# * delete checks that the server is managed by this house AND belongs to the
#   expected placement before sending DELETE, and reports acceptance, not
#   completion: Hetzner deletes asynchronously
class HetznerCloudClient

  BASE_URL = "https://api.hetzner.cloud/v1".freeze
  MANAGED_LABEL = "souls-house/managed".freeze
  PLACEMENT_LABEL = "souls-house/placement".freeze
  RETRYABLE_CODES = %w[rate_limit_exceeded locked conflict timeout unavailable].freeze
  CAPACITY_CODES = %w[resource_unavailable resource_limit_exceeded placement_error].freeze
  NETWORK_ERRORS = [SystemCallError, IOError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError].freeze

  class Error < StandardError

    attr_reader :status, :code

    def initialize(message, status: nil, code: nil)
      super(message)
      @status = status
      @code = code
    end

    # Whether the same read or delete may reasonably be tried again later.
    def retryable?
      RETRYABLE_CODES.include?(code) || status.to_i >= 500
    end

  end

  class NotConfigured < Error; end

  class Refused < Error

    def retryable? = false

  end

  class NotFound < Error; end
  # Stock or project limits: Hetzner could not supply this type/location now.
  class CapacityUnavailable < Error; end
  # A server with this name already exists in the project.
  class NameTaken < Error; end

  # The create request may or may not have produced a server. Never retryable
  # from here: a blind retry can buy a second machine.
  class CreateOutcomeUnknown < Error

    def retryable? = false

  end

  Server = Data.define(:id, :name, :status, :server_type, :location, :ipv4, :ipv6, :labels) do
    def self.from_api(json)
      new(
        id: json.fetch("id"),
        name: json["name"],
        status: json["status"],
        server_type: json.dig("server_type", "name"),
        location: json.dig("datacenter", "location", "name") || json.dig("location", "name"),
        ipv4: json.dig("public_net", "ipv4", "ip"),
        ipv6: json.dig("public_net", "ipv6", "ip"),
        labels: json["labels"] || {}
      )
    end

    def managed?
      labels[MANAGED_LABEL] == "true"
    end

    def placement_id
      labels[PLACEMENT_LABEL]
    end
  end

  # Hetzner accepted the delete; the server is gone only once the action
  # finishes, which a caller must reconcile (find_server returning nil).
  DeleteAccepted = Data.define(:server_id, :action_id, :action_status)

  def self.from_credentials
    config = Rails.application.credentials.hetzner_cloud || {}
    new(
      token: config[:api_token],
      allowed_server_types: Array(config[:allowed_server_types]),
      allowed_locations: Array(config[:allowed_locations])
    )
  end

  def initialize(token:, allowed_server_types:, allowed_locations:)
    require "net/http"

    @token = token.to_s
    @allowed_server_types = allowed_server_types.map(&:to_s).freeze
    @allowed_locations = allowed_locations.map(&:to_s).freeze
  end

  # Creates one resident server labelled with the house's placement record id.
  def create_server(name:, placement_id:, server_type:, location:, image:, ssh_keys:, user_data: nil, labels: {})
    refuse!("Server type is not on the allowlist") unless @allowed_server_types.include?(server_type.to_s)
    refuse!("Location is not on the allowlist") unless @allowed_locations.include?(location.to_s)
    refuse!("At least one SSH key is required") if Array(ssh_keys).empty?
    refuse!("A placement id is required") if placement_id.blank?

    payload = {
      name: name,
      server_type: server_type,
      location: location,
      image: image,
      ssh_keys: Array(ssh_keys),
      start_after_create: true,
      labels: labels.transform_keys(&:to_s).merge(MANAGED_LABEL => "true", PLACEMENT_LABEL => placement_id.to_s)
    }
    payload[:user_data] = user_data if user_data.present?

    server = request(:post, "/servers", payload)["server"]
    unless server.is_a?(Hash) && server["id"].is_a?(Integer) && server["id"].positive?
      raise CreateOutcomeUnknown.new("Hetzner Cloud create returned success without a valid server id", code: "outcome_unknown")
    end

    begin
      Server.from_api(server)
    rescue TypeError, NoMethodError, KeyError
      # A server may have been bought even though its description is malformed.
      raise CreateOutcomeUnknown.new("Hetzner Cloud create returned a malformed server", code: "outcome_unknown")
    end
  end

  def find_server(id)
    Server.from_api(request(:get, "/servers/#{Integer(id)}").fetch("server"))
  rescue NotFound
    nil
  end

  # Servers this house created for one placement (normally zero or one).
  def find_by_placement(placement_id)
    selector = "#{MANAGED_LABEL}=true,#{PLACEMENT_LABEL}=#{placement_id}"
    request(:get, "/servers", nil, label_selector: selector).fetch("servers").map { |json| Server.from_api(json) }
  end

  # Asks Hetzner to delete a server that belongs to the given placement.
  # Returns DeleteAccepted, or :already_absent when the server does not exist.
  def delete_server(id, placement_id:)
    refuse!("A placement id is required") if placement_id.blank?

    server = find_server(id)
    return :already_absent if server.nil?
    refuse!("Server is not the one requested") unless server.id == Integer(id)
    refuse!("Server is not managed by this house") unless server.managed?
    refuse!("Server belongs to a different placement") unless server.placement_id == placement_id.to_s

    action = request(:delete, "/servers/#{server.id}")["action"] || {}
    DeleteAccepted.new(server_id: server.id, action_id: action["id"], action_status: action["status"])
  rescue NotFound
    :already_absent
  end

  private

  def refuse!(message)
    raise Refused.new(message, code: "refused")
  end

  def request(method, path, payload = nil, query = nil)
    raise NotConfigured.new("Hetzner Cloud API token is not configured", code: "not_configured") if @token.blank?

    uri = URI("#{BASE_URL}#{path}")
    uri.query = URI.encode_www_form(query) if query.present?
    http_request = { get: Net::HTTP::Get, post: Net::HTTP::Post, delete: Net::HTTP::Delete }.fetch(method).new(uri)
    http_request["Authorization"] = "Bearer #{@token}"
    http_request["Content-Type"] = "application/json"
    http_request.body = payload.to_json if payload

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 30) do |http|
      http.request(http_request)
    end
    handle(response, method)
  rescue *NETWORK_ERRORS => e
    if method == :post
      raise CreateOutcomeUnknown.new("Hetzner Cloud create did not complete (#{e.class})", code: "outcome_unknown")
    end

    raise Error.new("Could not reach Hetzner Cloud (#{e.class})", code: "unavailable")
  end

  # Error text carries only Hetzner's error code and the HTTP status, never the
  # upstream message, which can echo request inputs.
  def handle(response, method)
    status = response.code.to_i
    body = response.body.present? ? JSON.parse(response.body) : {}
    body = {} unless body.is_a?(Hash)
    return body if status.between?(200, 299)

    error = body["error"].is_a?(Hash) ? body["error"] : {}
    code = error["code"].to_s.match?(/\A[a-z_]{1,64}\z/) ? error["code"] : "http_#{status}"
    message = "Hetzner Cloud #{code} (HTTP #{status})"
    raise CreateOutcomeUnknown.new(message, status:, code: "outcome_unknown") if method == :post && status >= 500

    raise error_class(code, status).new(message, status:, code:)
  rescue JSON::ParserError
    if method == :post
      raise CreateOutcomeUnknown.new("Hetzner Cloud create returned an unreadable response (HTTP #{status})", status:, code: "outcome_unknown")
    end

    raise Error.new("Hetzner Cloud returned an unreadable response (HTTP #{status})", status:, code: "invalid_response")
  end

  def error_class(code, status)
    return NotFound if code == "not_found" || status == 404
    return CapacityUnavailable if CAPACITY_CODES.include?(code)
    return NameTaken if code == "uniqueness_error"

    Error
  end

end

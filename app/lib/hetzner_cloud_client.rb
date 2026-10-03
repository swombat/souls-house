# Thin client for the Hetzner Cloud servers API, for resident placement.
#
# Deliberately small and not wired to anything yet: create, find and delete
# one server. It holds the procurement boundary, so it fails closed:
#
# * no default token; a blank token raises NotConfigured before any request
# * server types and locations must be on an explicit allowlist
# * SSH keys are required, so Hetzner never generates a root password, and
#   callers only ever receive Server values, which have no field for a
#   root_password even if a response carried one
# * POST is never retried: a timeout, 5xx or unreadable reply after a create
#   may still have bought a server, so it raises CreateOutcomeUnknown and the caller must look the
#   server up by its placement label before trying again
# * delete refuses any server that does not carry the managed label, so a
#   wrong id cannot remove a machine this house did not create
class HetznerCloudClient

  BASE_URL = "https://api.hetzner.cloud/v1".freeze
  MANAGED_LABEL = "souls-house/managed".freeze
  PLACEMENT_LABEL = "souls-house/placement".freeze
  RETRYABLE_CODES = %w[rate_limit_exceeded locked conflict timeout unavailable].freeze

  class Error < StandardError

    attr_reader :status, :code

    def initialize(message, status: nil, code: nil)
      super(message)
      @status = status
      @code = code
    end

    # Whether the same request may reasonably be tried again later.
    def retryable?
      RETRYABLE_CODES.include?(code) || status.to_i >= 500
    end

  end

  class NotConfigured < Error; end
  class Refused < Error; end
  class NotFound < Error; end
  # Stock or project limits: Hetzner could not supply this type/location now.
  class CapacityUnavailable < Error; end
  # A server with this name already exists in the project.
  class NameTaken < Error; end
  # The create request may or may not have produced a server.
  class CreateOutcomeUnknown < Error; end

  CAPACITY_CODES = %w[resource_unavailable resource_limit_exceeded placement_error].freeze

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
  end

  def self.from_credentials
    config = Rails.application.credentials.hetzner_cloud || {}
    new(
      token: config[:api_token],
      allowed_server_types: Array(config[:allowed_server_types]),
      allowed_locations: Array(config[:allowed_locations])
    )
  end

  def initialize(token:, allowed_server_types:, allowed_locations:, base_url: BASE_URL)
    require "net/http"

    @token = token.to_s
    @allowed_server_types = allowed_server_types.map(&:to_s).freeze
    @allowed_locations = allowed_locations.map(&:to_s).freeze
    @base_url = base_url.delete_suffix("/")
  end

  # Creates one resident server. placement_id is the house's stable placement
  # record id; it becomes a label so a lost response can be recovered with
  # find_by_placement.
  def create_server(name:, placement_id:, server_type:, location:, image:, ssh_keys:, user_data: nil, labels: {})
    unless @allowed_server_types.include?(server_type.to_s)
      raise Refused.new("Server type #{server_type.inspect} is not on the allowlist", code: "refused")
    end
    unless @allowed_locations.include?(location.to_s)
      raise Refused.new("Location #{location.inspect} is not on the allowlist", code: "refused")
    end
    raise Refused.new("At least one SSH key is required", code: "refused") if Array(ssh_keys).empty?
    raise Refused.new("A placement id is required", code: "refused") if placement_id.blank?

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

    body = request(:post, "/servers", payload)
    Server.from_api(body.fetch("server"))
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

  # Deletes a managed server. Returns :deleted, or :already_absent when the
  # server no longer exists (so a repeated delete is safe).
  def delete_server(id)
    server = find_server(id)
    return :already_absent if server.nil?
    raise Refused.new("Server #{server.id} is not managed by souls.house", code: "refused") unless server.managed?

    request(:delete, "/servers/#{server.id}")
    :deleted
  rescue NotFound
    :already_absent
  end

  private

  def request(method, path, payload = nil, query = nil)
    raise NotConfigured.new("Hetzner Cloud API token is not configured", code: "not_configured") if @token.blank?

    uri = URI("#{@base_url}#{path}")
    uri.query = URI.encode_www_form(query) if query.present?
    http_request = { get: Net::HTTP::Get, post: Net::HTTP::Post, delete: Net::HTTP::Delete }.fetch(method).new(uri)
    http_request["Authorization"] = "Bearer #{@token}"
    http_request["Content-Type"] = "application/json"
    http_request.body = payload.to_json if payload

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 30) do |http|
      http.request(http_request)
    end
    handle(response, method)
  rescue SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError => e
    if method == :post
      raise CreateOutcomeUnknown.new("Create request did not complete (#{e.class}); look up the placement before retrying", code: "outcome_unknown")
    end

    raise Error.new("Could not reach Hetzner Cloud (#{e.class})", code: "unavailable")
  end

  def handle(response, method)
    status = response.code.to_i
    body = response.body.present? ? JSON.parse(response.body) : {}
    return body if status.between?(200, 299)

    error = body["error"].is_a?(Hash) ? body["error"] : {}
    code = error["code"].presence || "http_#{status}"
    message = "Hetzner Cloud #{code}: #{error["message"].presence || "request failed"}"
    # A server-side failure on create is ambiguous in the same way a timeout is.
    raise CreateOutcomeUnknown.new(message, status:, code: "outcome_unknown") if method == :post && status >= 500
    raise error_class(code, status).new(message, status:, code:)
  rescue JSON::ParserError
    if method == :post
      raise CreateOutcomeUnknown.new("Create returned an unreadable response (HTTP #{status})", status:, code: "outcome_unknown")
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

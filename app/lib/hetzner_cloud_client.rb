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
  # Discovery only, like the placement label: never idempotency or proof.
  OPERATION_LABEL = "souls-house/operation".freeze
  LIST_PAGE_SIZE = 50
  # More pages than this for one label selector is not a listing we trust.
  LIST_MAX_PAGES = 20
  PAGINATION_KEYS = %w[page per_page next_page last_page total_entries].freeze
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
  # A paginated listing could not be read completely. Callers must not treat
  # the pages they did get as the whole answer.
  class IncompleteListing < Error; end

  # The create request may or may not have produced a server. Never retryable
  # from here: a blind retry can buy a second machine.
  class CreateOutcomeUnknown < Error

    def retryable? = false

  end

  Server = Data.define(:id, :name, :status, :server_type, :location, :image_id, :ipv4, :ipv6, :labels) do
    def self.from_api(json)
      new(
        id: json.fetch("id"),
        name: json["name"],
        status: json["status"],
        server_type: json.dig("server_type", "name"),
        location: json.dig("datacenter", "location", "name") || json.dig("location", "name"),
        image_id: json["image"].is_a?(Hash) ? json["image"]["id"] : nil,
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

    def operation_id
      labels[OPERATION_LABEL]
    end
  end

  # A create returns its server and the action that boots it. The action id is
  # kept so reconciliation can tell "still starting" from "failed to start".
  Created = Data.define(:server, :action_id, :action_status)

  # Hetzner action states are running, success and error.
  Action = Data.define(:id, :command, :status, :error_code)

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
  # Returns the Server; use create_server_with_action for the boot action too.
  def create_server(**kwargs)
    create_server_with_action(**kwargs).server
  end

  def create_server_with_action(name:, placement_id:, server_type:, location:, image:, ssh_keys:, user_data: nil, labels: {})
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

    body = request(:post, "/servers", payload)
    server = body["server"]
    unless server.is_a?(Hash) && server["id"].is_a?(Integer) && server["id"].positive?
      raise CreateOutcomeUnknown.new("Hetzner Cloud create returned success without a valid server id", code: "outcome_unknown")
    end

    begin
      action = body["action"].is_a?(Hash) ? body["action"] : {}
      action_id = action["id"].is_a?(Integer) && action["id"].positive? ? action["id"] : nil
      Created.new(server: Server.from_api(server), action_id:, action_status: action["status"])
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
    list_servers("#{MANAGED_LABEL}=true,#{PLACEMENT_LABEL}=#{placement_id}")
  end

  # Servers this house created for one procurement operation, every page.
  def find_by_operation(operation_id)
    list_servers("#{MANAGED_LABEL}=true,#{OPERATION_LABEL}=#{operation_id}")
  end

  # Returns the action, or nil when Hetzner says it does not exist. An answer
  # about a different action is an error, never a substitute.
  def find_action(id)
    action_from(request(:get, "/actions/#{Integer(id)}").fetch("action"), expected_id: Integer(id))
  rescue NotFound
    nil
  end

  # The create_server actions Hetzner holds for one server (normally one),
  # for recovering a boot action whose id the house never received.
  def create_actions_for(server_id)
    body = request(:get, "/servers/#{Integer(server_id)}/actions", nil, command: "create_server", per_page: LIST_PAGE_SIZE)
    actions = body["actions"]
    pagination = body.dig("meta", "pagination")
    incomplete!("of actions is missing pagination") unless actions.is_a?(Array) && pagination.is_a?(Hash)
    incomplete!("of actions is missing pagination") unless PAGINATION_KEYS.all? { |key| pagination.key?(key) }
    # One page only, and it must say it holds everything.
    unless pagination["page"] == 1 && pagination["next_page"].nil? && pagination["last_page"] == 1 &&
        pagination["total_entries"] == actions.size && actions.size <= LIST_PAGE_SIZE
      incomplete!("of actions is not complete")
    end

    actions.map { |json| action_from(json) }
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

  def action_from(json, expected_id: nil)
    raise Error.new("Hetzner Cloud action is malformed", code: "invalid_response") unless json.is_a?(Hash) && json["id"].is_a?(Integer)
    if expected_id && json["id"] != expected_id
      raise Error.new("Hetzner Cloud returned a different action", code: "mismatched_action")
    end

    error = json["error"].is_a?(Hash) ? json["error"]["code"] : nil
    Action.new(id: json["id"], command: json["command"], status: json["status"], error_code: error)
  end

  # Follows Hetzner's pagination to the end. Any page that cannot be read,
  # or pagination metadata that does not add up, raises rather than returning
  # a partial list: an absent server must never be inferred from a short read.
  def list_servers(selector)
    servers = []
    page = 1
    loop do
      raise IncompleteListing.new("Hetzner Cloud listing has too many pages", code: "incomplete_listing") if page > LIST_MAX_PAGES

      body = request(:get, "/servers", nil, label_selector: selector, page:, per_page: LIST_PAGE_SIZE)
      batch = body["servers"]
      pagination = body.dig("meta", "pagination")
      incomplete!("is missing pagination") unless batch.is_a?(Array) && pagination.is_a?(Hash)
      incomplete!("is missing pagination") unless PAGINATION_KEYS.all? { |key| pagination.key?(key) }

      total = pagination["total_entries"]
      last_page = pagination["last_page"]
      next_page = pagination["next_page"]
      unless pagination["page"] == page && pagination["per_page"] == LIST_PAGE_SIZE &&
          total.is_a?(Integer) && total >= 0 && last_page.is_a?(Integer) && last_page >= 1 &&
          batch.size <= LIST_PAGE_SIZE
        incomplete!("pagination is inconsistent")
      end

      servers.concat(batch.map { |json| Server.from_api(json) })
      if next_page.nil?
        # The last page must be the last page, and everything must be here.
        incomplete!("ended early") unless page == last_page && servers.size == total
        break
      end
      unless next_page == page + 1 && next_page <= last_page && batch.size == LIST_PAGE_SIZE
        incomplete!("pagination is inconsistent")
      end

      page = next_page
    end
    servers
  rescue TypeError, NoMethodError, KeyError
    raise IncompleteListing.new("Hetzner Cloud listing is malformed", code: "incomplete_listing")
  end

  def incomplete!(detail)
    raise IncompleteListing.new("Hetzner Cloud listing #{detail}", code: "incomplete_listing")
  end

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
    # A create that timed out or failed server-side may still have bought
    # something, whatever error code came with it.
    if method == :post && (status >= 500 || status == 408)
      raise CreateOutcomeUnknown.new(message, status:, code: "outcome_unknown")
    end

    raise error_class(code, status).new(message, status:, code:)
  rescue JSON::ParserError
    if method == :post
      raise CreateOutcomeUnknown.new("Hetzner Cloud create returned an unreadable response (HTTP #{status})", status:, code: "outcome_unknown")
    end

    raise Error.new("Hetzner Cloud returned an unreadable response (HTTP #{status})", status:, code: "invalid_response")
  end

  # The status decides first: a server-side failure is never read as
  # "absent" or "refused" because of the code that came with it.
  def error_class(code, status)
    return Error unless status.between?(400, 499) && status != 408
    return NotFound if status == 404 && [ "not_found", "http_404" ].include?(code)
    return CapacityUnavailable if CAPACITY_CODES.include?(code)
    return NameTaken if code == "uniqueness_error"

    Error
  end

end

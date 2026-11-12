# Thin client for the Boat sandboxes API (boat.dev), the second home for
# residents after Hetzner Cloud: small, mostly asleep residents, and the
# placeholder while CX stock is short (ePokyY, slice 2).
#
# Not wired to anything yet. It holds the provider boundary the same way
# HetznerCloudClient does, and fails closed:
#
# * no default token; a blank token raises NotConfigured before any request,
#   and requests only ever go to the fixed production API origin
# * sizes must be on an explicit allowlist
# * every create carries an Idempotency-Key. Boat binds the key to the first
#   sandbox it makes and answers a retry with the same body by returning that
#   sandbox, so a create with an unknown outcome may be sent again with the
#   same key and body. A create sent without a key is refused here.
# * every create is noEnv: a resident's box gets none of the account's
#   environment, secrets or credentials, and cannot act on the account
# * labels (managed, placement, operation) support discovery, not proof
# * stop, resume and delete check that the sandbox is managed by this house
#   and belongs to the expected placement before sending anything
# * Boat has no idle detection: auto-stop is a lifetime counted from create
#   or resume. The house decides when a resident is idle and calls stop; the
#   lifetime here is only a backstop
class BoatClient

  BASE_URL = "https://boat.dev/api/v1".freeze
  # Boat's documented sandbox id shape (every id field in the API reference).
  # One check for ids Boat hands us and ids we put in a request path.
  SANDBOX_ID = /\Abx_[23456789abcdefghjkmnpqrstuvwxyz]{8}\z/
  MANAGED_LABEL = "souls-house/managed".freeze
  PLACEMENT_LABEL = "souls-house/placement".freeze
  OPERATION_LABEL = "souls-house/operation".freeze
  LIST_PAGE_SIZE = 100
  LIST_MAX_PAGES = 20
  # States a sandbox moves through on its own; poll, don't act.
  TRANSITIONAL_STATES = %w[init provisioning provisioned cloning archiving].freeze
  AWAKE_STATES = %w[ready idle running].freeze
  STOPPED_STATE = "archived".freeze
  RETRYABLE_CODES = %w[rate_limited idempotency_in_progress sandbox_direct_failed unavailable].freeze
  # Boat's documented capacity answers: 503 no_ready_machine / out_of_capacity
  # (nothing started), 429 rate_limited / limit_reached / member_limit_reached
  # (a start or concurrent-sandbox limit).
  CAPACITY_CODES = %w[no_ready_machine out_of_capacity rate_limited limit_reached member_limit_reached].freeze
  NETWORK_ERRORS = [ SystemCallError, IOError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError ].freeze

  class Error < StandardError

    attr_reader :status, :code

    def initialize(message, status: nil, code: nil)
      super(message)
      @status = status
      @code = code
    end

    def retryable?
      RETRYABLE_CODES.include?(code) || status.to_i >= 500
    end

  end

  class NotConfigured < Error; end

  class Refused < Error

    def retryable? = false

  end

  class NotFound < Error; end
  # No machine of this size now, or an account limit (active sandboxes,
  # starts per hour/day) is reached.
  class CapacityUnavailable < Error; end

  # The stopped disk was deleted after Boat's retention period: resume and
  # fork can never succeed again. The home must come from a backup.
  class SnapshotExpired < Error

    def retryable? = false

  end

  class IncompleteListing < Error; end

  # The create may or may not have made a sandbox. Unlike Hetzner, a retry
  # with the same Idempotency-Key and body is safe; a retry without them is
  # not, so this stays non-retryable here and the operation layer decides.
  class CreateOutcomeUnknown < Error

    def retryable? = false

  end

  Sandbox = Data.define(:id, :name, :state, :size, :error, :stopped_at, :data_expired_at, :labels,
    :setup_status, :setup_error) do
    def self.from_api(json)
      new(
        id: usable_id(json.fetch("id")),
        name: json["name"],
        state: json["state"],
        size: json["type"],
        error: json["error"],
        stopped_at: json["stoppedAt"],
        data_expired_at: json["dataExpiredAt"],
        labels: json["labels"].is_a?(Hash) ? json["labels"] : {},
        # Outcome of the create-time setupScript: pending, running, done or
        # failed; nil when the sandbox was created without one.
        setup_status: json["setupStatus"],
        setup_error: json["setupError"]
      )
    end

    def self.usable_id(id)
      raise KeyError, "sandbox id is missing or malformed" unless BoatClient.sandbox_id?(id)

      id
    end

    def managed? = labels[MANAGED_LABEL] == "true"
    def placement_id = labels[PLACEMENT_LABEL]
    def operation_id = labels[OPERATION_LABEL]
    def awake? = AWAKE_STATES.include?(state)
    def stopped? = state == STOPPED_STATE
    def transitional? = TRANSITIONAL_STATES.include?(state)
    def failed? = state == "error"
  end

  # Boat accepted the delete; deletion runs asynchronously as an operation.
  DeleteAccepted = Data.define(:sandbox_id, :operation_id)

  Limits = Data.define(:access_tier, :can_start, :max_active_sandboxes, :starts_per_day, :wallet_dollars,
    :included_hours_remaining, :included_period_end)

  def self.sandbox_id?(id) = id.is_a?(String) && id.match?(SANDBOX_ID)

  def self.from_credentials
    config = Rails.application.credentials.boat || {}
    new(token: config[:api_token], allowed_sizes: Array(config[:allowed_sizes]).presence || %w[small])
  end

  def initialize(token:, allowed_sizes:)
    require "net/http"

    @token = token.to_s
    @allowed_sizes = allowed_sizes.map(&:to_s).freeze
  end

  # Creates one resident sandbox. idempotency_key must be the operation's
  # durable public id: the same key with the same arguments returns the same
  # sandbox, never a second one. setup_script runs once the sandbox is ready
  # (it is Boat's only first-boot hook; there is no cloud-init).
  def create_sandbox(idempotency_key:, name:, placement_id:, operation_id:, size:, setup_script: nil,
    ttl_seconds: nil, labels: {})
    refuse!("an Idempotency-Key is required") if idempotency_key.blank?
    refuse!("size #{size} is not allowed") unless @allowed_sizes.include?(size.to_s)
    refuse!("a placement id is required") if placement_id.blank?
    refuse!("an operation id is required") if operation_id.blank?
    refuse!("setup script is over 64 KB") if setup_script && setup_script.bytesize > 65_536

    payload = {
      name:,
      type: size.to_s,
      noEnv: true,
      labels: labels.transform_keys(&:to_s).merge(
        MANAGED_LABEL => "true", PLACEMENT_LABEL => placement_id.to_s, OPERATION_LABEL => operation_id.to_s
      )
    }
    payload[:setupScript] = setup_script if setup_script
    # Omitted, Boat archives the sandbox after its default TTL (3600 s). The
    # house runs the idle stop itself; the TTL is only a backstop.
    payload[:ttlSeconds] = ttl_seconds if ttl_seconds

    body = request(:post, "/sandboxes", payload, headers: { "Idempotency-Key" => idempotency_key.to_s })
    # A 2xx whose sandbox has no usable id means Boat may have made one we
    # cannot name: that is outcome-unknown, reconciled by label, not an error.
    sandbox_from(body)
  rescue Error => e
    raise if e.is_a?(CreateOutcomeUnknown) || e.code != "invalid_response"

    raise CreateOutcomeUnknown.new("Boat create returned no usable sandbox id", code: "outcome_unknown")
  end

  def find_sandbox(id)
    sandbox_from(request(:get, "/sandboxes/#{path_id(id)}"))
  rescue NotFound
    nil
  end

  def find_by_placement(placement_id)
    list_sandboxes(PLACEMENT_LABEL => placement_id.to_s)
  end

  def find_by_operation(operation_id)
    list_sandboxes(OPERATION_LABEL => operation_id.to_s)
  end

  # Wakes a stopped sandbox. Resuming one that is already awake is harmless.
  def resume_sandbox(id, placement_id:)
    guard_owned!(id, placement_id)
    sandbox_from(request(:post, "/sandboxes/#{path_id(id)}/resume", {}))
  end

  # Stops and archives a sandbox; the disk is kept. Archiving is not billed.
  def stop_sandbox(id, placement_id:)
    guard_owned!(id, placement_id)
    sandbox_from(request(:post, "/sandboxes/#{path_id(id)}/stop", {}))
  end

  def delete_sandbox(id, placement_id:)
    guard_owned!(id, placement_id)
    body = request(:delete, "/sandboxes/#{path_id(id)}", nil, headers: { "X-Ascii-Confirm-Delete" => id.to_s })
    DeleteAccepted.new(sandbox_id: id.to_s, operation_id: body["operationId"] || body.dig("operation", "id"))
  end

  def limits
    body = request(:get, "/limits")
    Limits.new(
      access_tier: body["accessTier"],
      can_start: body["canStart"],
      max_active_sandboxes: body.dig("currentLimits", "activeSandboxes"),
      starts_per_day: body.dig("currentLimits", "creationRequestsPerDay"),
      wallet_dollars: body.dig("wallet", "balanceDollars"),
      included_hours_remaining: body.dig("planIncluded", "vmHoursRemaining"),
      included_period_end: body.dig("planIncluded", "periodEnd")
    )
  end

  private

  def guard_owned!(id, placement_id)
    sandbox = find_sandbox(id)
    raise NotFound.new("Boat sandbox not found", status: 404, code: "not_found") if sandbox.nil?
    refuse!("sandbox is not managed by this house") unless sandbox.managed?
    refuse!("sandbox belongs to another placement") unless sandbox.placement_id == placement_id.to_s
  end

  def path_id(id)
    self.class.sandbox_id?(id) ? id : refuse!("malformed sandbox id")
  end

  def sandbox_from(body)
    json = body["sandbox"].is_a?(Hash) ? body["sandbox"] : body
    Sandbox.from_api(json)
  rescue KeyError, TypeError
    raise Error.new("Boat returned a sandbox without an id", code: "invalid_response")
  end

  def list_sandboxes(labels)
    sandboxes = []
    cursor = nil
    LIST_MAX_PAGES.times do
      query = [ [ "limit", LIST_PAGE_SIZE ] ] + labels.map { |key, value| [ "label", "#{key}=#{value}" ] }
      query << [ "cursor", cursor ] if cursor
      body = request(:get, "/sandboxes", nil, query:)
      page = body["sandboxes"]
      incomplete!("has no sandboxes array") unless page.is_a?(Array)
      sandboxes.concat(page.map { |json| Sandbox.from_api(json) })
      info = body["pageInfo"].is_a?(Hash) ? body["pageInfo"] : {}
      return sandboxes unless info["hasMore"] == true

      cursor = info["nextCursor"].presence || incomplete!("says hasMore without a cursor")
    end
    incomplete!("has more than #{LIST_MAX_PAGES} pages")
  rescue KeyError, TypeError, NoMethodError
    incomplete!("is malformed")
  end

  def incomplete!(detail)
    raise IncompleteListing.new("Boat listing #{detail}", code: "incomplete_listing")
  end

  def refuse!(message)
    raise Refused.new(message, code: "refused")
  end

  def request(method, path, payload = nil, query: nil, headers: {})
    raise NotConfigured.new("Boat API token is not configured", code: "not_configured") if @token.blank?

    uri = URI("#{BASE_URL}#{path}")
    uri.query = URI.encode_www_form(query) if query.present?
    http_request = { get: Net::HTTP::Get, post: Net::HTTP::Post, delete: Net::HTTP::Delete }.fetch(method).new(uri)
    http_request["Authorization"] = "Bearer #{@token}"
    http_request["Content-Type"] = "application/json"
    headers.each { |key, value| http_request[key] = value }
    http_request.body = payload.to_json if payload

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 60) do |http|
      http.request(http_request)
    end
    handle(response, create: method == :post && path == "/sandboxes")
  rescue *NETWORK_ERRORS => e
    raise CreateOutcomeUnknown.new("Boat create did not complete (#{e.class})", code: "outcome_unknown") if method == :post && path == "/sandboxes"

    raise Error.new("Could not reach Boat (#{e.class})", code: "unavailable")
  end

  # Error text carries only Boat's error code and the HTTP status, never the
  # upstream message, which can echo request inputs.
  def handle(response, create:)
    status = response.code.to_i
    body = response.body.present? ? JSON.parse(response.body) : {}
    body = {} unless body.is_a?(Hash)
    return body if status.between?(200, 299)

    raw = body["code"] || (body["error"].is_a?(Hash) ? body["error"]["code"] : nil)
    code = raw.to_s.match?(/\A[a-z_]{1,64}\z/) ? raw : "http_#{status}"
    message = "Boat #{code} (HTTP #{status})"
    # Boat documents that a create answered 503 no_ready_machine (or refused
    # for an account limit) made nothing, so it is capacity, not unknown.
    raise CapacityUnavailable.new(message, status:, code:) if CAPACITY_CODES.include?(code) && [ 429, 503 ].include?(status)
    raise CreateOutcomeUnknown.new(message, status:, code: "outcome_unknown") if create && (status >= 500 || status == 408)

    raise error_class(code, status).new(message, status:, code:)
  rescue JSON::ParserError
    raise CreateOutcomeUnknown.new("Boat create returned an unreadable response (HTTP #{status})", status:, code: "outcome_unknown") if create

    raise Error.new("Boat returned an unreadable response (HTTP #{status})", status:, code: "invalid_response")
  end

  # The status decides first: a server-side failure is never read as
  # "absent" or "refused" because of the code that came with it.
  def error_class(code, status)
    return Error unless status.between?(400, 499) && status != 408
    return NotFound if status == 404
    return SnapshotExpired if code == "snapshot_data_expired"
    return CapacityUnavailable if CAPACITY_CODES.include?(code)

    Error
  end

end

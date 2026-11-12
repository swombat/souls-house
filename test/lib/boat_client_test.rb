require "test_helper"
require "webmock/minitest"

class BoatClientTest < ActiveSupport::TestCase

  API = "https://boat.dev/api/v1".freeze
  LABELS = { "souls-house/managed" => "true", "souls-house/placement" => "7", "souls-house/operation" => "bop-1" }.freeze

  setup do
    WebMock.disable_net_connect!
    @client = BoatClient.new(token: "synthetic-token", allowed_sizes: %w[small])
  end

  def sandbox_json(id: "bx_23456789", state: "ready", labels: LABELS, stop: nil)
    { "id" => id, "name" => "souls-house-bop-1", "state" => state, "type" => "small", "error" => nil,
      "stoppedAt" => nil, "dataExpiredAt" => nil, "labels" => labels, "stop" => stop }
  end

  def stop_json(**overrides)
    { "id" => "stop_3f9a1c2e7b4d5a60", "status" => "pending", "requestedAt" => "2026-11-12T10:00:00Z",
      "lastAttemptAt" => nil, "error" => nil, "endedAt" => nil }.merge(overrides.transform_keys(&:to_s))
  end

  def create!(**overrides)
    @client.create_sandbox(**{ idempotency_key: "bop-1", name: "souls-house-bop-1", placement_id: 7,
                               operation_id: "bop-1", size: "small", setup_script: "echo runner" }.merge(overrides))
  end

  def stub_find(id: "bx_23456789", **json)
    stub_request(:get, "#{API}/sandboxes/#{id}").to_return(status: 200, body: { sandbox: sandbox_json(id:, **json) }.to_json)
  end

  test "creates a labelled, no-env sandbox with auto-stop off under the operation's idempotency key" do
    stub = stub_request(:post, "#{API}/sandboxes")
      .with(headers: { "Authorization" => "Bearer synthetic-token", "Idempotency-Key" => "bop-1" }) do |request|
        body = JSON.parse(request.body)
        body["noEnv"] == true && body["type"] == "small" && !body.key?("size") && body["labels"] == LABELS &&
          body["setupScript"] == "echo runner" && body.key?("ttlSeconds") && body["ttlSeconds"].nil? &&
          !body.key?("autoStopSeconds")
      end
      .to_return(status: 202, body: { sandbox: sandbox_json(state: "provisioning") }.to_json)

    sandbox = create!

    assert_requested stub
    assert_equal "bx_23456789", sandbox.id
    assert sandbox.transitional?
    assert sandbox.managed?
    assert_equal "7", sandbox.placement_id
    assert_equal "bop-1", sandbox.operation_id
  end

  test "a retried create sends the same key and the same body" do
    bodies = []
    keys = []
    stub_request(:post, "#{API}/sandboxes").to_return do |request|
      bodies << request.body
      keys << request.headers["Idempotency-Key"]
      { status: 202, body: { sandbox: sandbox_json }.to_json }
    end

    first = create!
    second = create!

    assert_equal first, second
    assert_equal %w[bop-1 bop-1], keys
    assert_equal 1, bodies.uniq.size
  end

  test "an accepted create without a usable sandbox id has an unknown outcome" do
    [ { sandbox: sandbox_json.except("id") }, { sandbox: sandbox_json.merge("id" => nil) },
      { sandbox: sandbox_json.merge("id" => "") }, { sandbox: sandbox_json.merge("id" => "not-a-sandbox-id") },
      { sandbox: sandbox_json.merge("id" => "bx_0000000l") }, { sandbox: sandbox_json.merge("id" => 12_345_678) },
      { ok: true } ].each do |body|
      stub_request(:post, "#{API}/sandboxes").to_return(status: 202, body: body.to_json)
      error = assert_raises(BoatClient::CreateOutcomeUnknown) { create! }
      assert_equal "outcome_unknown", error.code
    end
  end

  test "a read of a sandbox without an id is an invalid response, not outcome-unknown" do
    stub_request(:get, "#{API}/sandboxes/bx_23456789").to_return(status: 200, body: { sandbox: sandbox_json.merge("id" => nil) }.to_json)
    error = assert_raises(BoatClient::Error) { @client.find_sandbox("bx_23456789") }
    assert_not_kind_of BoatClient::CreateOutcomeUnknown, error
    assert_equal "invalid_response", error.code
  end

  test "an id the client accepts from Boat is one it can use in a path, and the reverse" do
    [ "bx_23456789", "bx_f7k2q9hd" ].each { |id| assert BoatClient.sandbox_id?(id), id }
    [ "not-a-sandbox-id", "bx_0000000l", "bx_2345678", "bx_234567890", "BX_23456789", "bx_23456789\n", nil, 1 ].each do |id|
      assert_not BoatClient.sandbox_id?(id), id.inspect
      assert_raises(BoatClient::Refused) { @client.find_sandbox(id) }
    end
    stub_request(:get, "#{API}/sandboxes/bx_23456789").to_return(status: 200,
      body: { sandbox: sandbox_json.merge("id" => "not-a-sandbox-id") }.to_json)
    assert_equal "invalid_response", assert_raises(BoatClient::Error) { @client.find_sandbox("bx_23456789") }.code
  end

  test "refuses unconfigured, keyless, off-allowlist and oversized creates before any request" do
    assert_raises(BoatClient::NotConfigured) { BoatClient.new(token: nil, allowed_sizes: %w[small]).create_sandbox(
      idempotency_key: "k", name: "n", placement_id: 1, operation_id: "o", size: "small") }
    assert_raises(BoatClient::Refused) { create!(idempotency_key: nil) }
    assert_raises(BoatClient::Refused) { create!(size: "large") }
    assert_raises(BoatClient::Refused) { create!(placement_id: nil) }
    assert_raises(BoatClient::Refused) { create!(operation_id: "") }
    assert_raises(BoatClient::Refused) { create!(setup_script: "x" * 65_537) }
    assert_not_requested :any, /boat\.dev/
  end

  test "a create that times out, fails server-side or answers garbage has an unknown outcome" do
    stub_request(:post, "#{API}/sandboxes").to_timeout
    error = assert_raises(BoatClient::CreateOutcomeUnknown) { create! }
    assert_not error.retryable?

    stub_request(:post, "#{API}/sandboxes").to_return(status: 502, body: { code: "sandbox_direct_failed" }.to_json)
    assert_raises(BoatClient::CreateOutcomeUnknown) { create! }

    stub_request(:post, "#{API}/sandboxes").to_return(status: 202, body: "<html>")
    assert_raises(BoatClient::CreateOutcomeUnknown) { create! }
  end

  test "a refused create is an error with Boat's code and no upstream message or secret" do
    stub_request(:post, "#{API}/sandboxes").to_return(status: 400,
      body: { type: "sandbox.error", code: "invalid_setup_script", message: "script echo synthetic-token is bad" }.to_json)

    error = assert_raises(BoatClient::Error) { create! }

    assert_equal "invalid_setup_script", error.code
    assert_not_includes error.message, "synthetic-token"
    assert_not_includes error.message, "echo"
  end

  test "no machine or an account limit is capacity, not a failure of the house" do
    { 503 => %w[no_ready_machine out_of_capacity], 429 => %w[rate_limited limit_reached member_limit_reached] }
      .each do |status, codes|
        codes.each do |code|
          stub_request(:post, "#{API}/sandboxes").to_return(status:, body: { code: }.to_json)
          assert_equal code, assert_raises(BoatClient::CapacityUnavailable) { create! }.code
        end
      end
  end

  test "an undocumented 429 code on create is not read as capacity" do
    stub_request(:post, "#{API}/sandboxes").to_return(status: 429, body: { code: "active_sandbox_limit" }.to_json)
    error = assert_raises(BoatClient::Error) { create! }
    assert_not_kind_of BoatClient::CapacityUnavailable, error
  end

  test "find returns nil for a missing sandbox and raises on a server error" do
    stub_request(:get, "#{API}/sandboxes/bx_23456789").to_return(status: 404, body: { code: "not_found" }.to_json)
    assert_nil @client.find_sandbox("bx_23456789")

    stub_request(:get, "#{API}/sandboxes/bx_23456789").to_return(status: 500, body: {}.to_json)
    error = assert_raises(BoatClient::Error) { @client.find_sandbox("bx_23456789") }
    assert error.retryable?
  end

  test "find by label returns every match, so the caller can tell zero, one and many apart" do
    stub_request(:get, "#{API}/sandboxes").with(query: { "limit" => "100", "label" => "souls-house/operation=bop-1" })
      .to_return(status: 200, body: { sandboxes: [ sandbox_json, sandbox_json(id: "bx_33333333") ],
                                      pageInfo: { hasMore: false } }.to_json)

    assert_equal %w[bx_23456789 bx_33333333], @client.find_by_operation("bop-1").map(&:id)
  end

  test "a listing that cannot be read completely is never taken as the whole answer" do
    stub_request(:get, "#{API}/sandboxes").with(query: hash_including("label" => "souls-house/placement=7"))
      .to_return(status: 200, body: { sandboxes: [ sandbox_json ], pageInfo: { hasMore: true } }.to_json)
    assert_raises(BoatClient::IncompleteListing) { @client.find_by_placement(7) }

    stub_request(:get, "#{API}/sandboxes").with(query: hash_including("label" => "souls-house/placement=7"))
      .to_return(status: 200, body: { data: [] }.to_json)
    assert_raises(BoatClient::IncompleteListing) { @client.find_by_placement(7) }
  end

  test "follows the cursor across pages" do
    stub_request(:get, "#{API}/sandboxes").with(query: { "limit" => "100", "label" => "souls-house/placement=7" })
      .to_return(status: 200, body: { sandboxes: [ sandbox_json ], pageInfo: { hasMore: true, nextCursor: "c2" } }.to_json)
    stub_request(:get, "#{API}/sandboxes").with(query: { "limit" => "100", "label" => "souls-house/placement=7", "cursor" => "c2" })
      .to_return(status: 200, body: { sandboxes: [ sandbox_json(id: "bx_44444444") ], pageInfo: { hasMore: false } }.to_json)

    assert_equal %w[bx_23456789 bx_44444444], @client.find_by_placement(7).map(&:id)
  end

  test "resume and stop act only on this house's sandbox for the expected placement" do
    stub_find(state: "archived")
    resume = stub_request(:post, "#{API}/sandboxes/bx_23456789/resume")
      .with { |request| body = JSON.parse(request.body); body.key?("ttlSeconds") && body["ttlSeconds"].nil? }
      .to_return(status: 202, body: { sandbox: sandbox_json(state: "provisioning") }.to_json)
    stop = stub_request(:post, "#{API}/sandboxes/bx_23456789/stop")
      .with { |request| JSON.parse(request.body) == { "force" => false } }
      .to_return(status: 202, body: { status: "archiving", operation: stop_json, sandbox: sandbox_json(state: "archiving") }.to_json)

    assert @client.resume_sandbox("bx_23456789", placement_id: 7).transitional?
    accepted = @client.stop_sandbox("bx_23456789", placement_id: 7)
    assert_equal "stop_3f9a1c2e7b4d5a60", accepted.stop.id
    assert accepted.stop.live?
    assert_not accepted.already_stopped
    assert_requested resume
    assert_requested stop

    assert_raises(BoatClient::Refused) { @client.stop_sandbox("bx_23456789", placement_id: 8) }

    stub_find(labels: { "souls-house/placement" => "7" })
    assert_raises(BoatClient::Refused) { @client.resume_sandbox("bx_23456789", placement_id: 7) }
    assert_requested resume, times: 1
    assert_requested stop, times: 1
  end

  test "a stop on a stopped sandbox says so and returns its last stop" do
    stub_find(state: "archived")
    stub_request(:post, "#{API}/sandboxes/bx_23456789/stop").to_return(status: 200, body: {
      status: "archived", operation: stop_json(status: "completed", requestedAt: nil, endedAt: "2026-11-12T10:00:00Z")
    }.to_json)

    accepted = @client.stop_sandbox("bx_23456789", placement_id: 7)

    assert accepted.already_stopped
    assert accepted.stop.completed?
    assert_nil accepted.stop.requested_at
  end

  test "a stop answer without a well-formed stop operation is an invalid response" do
    stub_find
    [ {}, { operation: { id: "stop_1", status: "cancelled" } }, { operation: { id: "../x", status: "pending" } },
      { operation: stop_json(requestedAt: "yesterday") } ].each do |body|
      stub_request(:post, "#{API}/sandboxes/bx_23456789/stop").to_return(status: 202, body: body.to_json)

      error = assert_raises(BoatClient::Error) { @client.stop_sandbox("bx_23456789", placement_id: 7) }
      assert_equal "invalid_response", error.code
    end
  end

  test "a sandbox carries its last stop, and pending and failing stops are live" do
    stub_find(stop: stop_json(status: "failing"))
    assert @client.find_sandbox("bx_23456789").live_stop?

    stub_find(state: "archived", stop: stop_json(status: "completed", requestedAt: nil))
    sandbox = @client.find_sandbox("bx_23456789")
    assert_not sandbox.live_stop?
    assert sandbox.stop.completed?

    stub_find
    assert_nil @client.find_sandbox("bx_23456789").stop
  end

  test "find_stop reads one stop by id, with the requestedAt the sandbox drops" do
    stub_request(:get, "#{API}/sandboxes/bx_23456789/stops/stop_3f9a1c2e7b4d5a60").to_return(status: 200, body: {
      ok: true, type: "stop.status", id: "stop_3f9a1c2e7b4d5a60",
      stop: stop_json(status: "completed", endedAt: "2026-11-12T10:01:00Z")
    }.to_json)

    stop = @client.find_stop("bx_23456789", "stop_3f9a1c2e7b4d5a60")

    assert_equal Time.iso8601("2026-11-12T10:00:00Z"), stop.requested_at
    assert stop.completed?
    assert_raises(BoatClient::Refused) { @client.find_stop("bx_23456789", "../stops") }

    stub_request(:get, "#{API}/sandboxes/bx_23456789/stops/stop_0000000000000000").to_return(status: 404, body: "{}")
    assert_nil @client.find_stop("bx_23456789", "stop_0000000000000000")

    stub_request(:get, "#{API}/sandboxes/bx_23456789/stops/stop_1111111111111111")
      .to_return(status: 200, body: { stop: stop_json }.to_json)
    error = assert_raises(BoatClient::Error) { @client.find_stop("bx_23456789", "stop_1111111111111111") }
    assert_equal "invalid_response", error.code
  end

  test "a resume blocked by a stop holding the machine carries Retry-After" do
    stub_find(state: "archiving")
    stub_request(:post, "#{API}/sandboxes/bx_23456789/resume")
      .to_return(status: 409, headers: { "Retry-After" => "20" }, body: { error: { code: "sandbox_stopping" } }.to_json)

    error = assert_raises(BoatClient::SandboxStopping) { @client.resume_sandbox("bx_23456789", placement_id: 7) }
    assert_equal 20, error.retry_after
  end

  test "a resume whose stopped disk has expired says so" do
    stub_find(state: "archived")
    stub_request(:post, "#{API}/sandboxes/bx_23456789/resume").to_return(status: 409, body: { code: "snapshot_data_expired" }.to_json)

    error = assert_raises(BoatClient::SnapshotExpired) { @client.resume_sandbox("bx_23456789", placement_id: 7) }
    assert_not error.retryable?
  end

  test "delete confirms with the sandbox id and refuses a foreign or malformed one" do
    stub_find
    delete = stub_request(:delete, "#{API}/sandboxes/bx_23456789")
      .with(headers: { "X-Ascii-Confirm-Delete" => "bx_23456789" })
      .to_return(status: 202, body: { operationId: "del_1" }.to_json)

    accepted = @client.delete_sandbox("bx_23456789", placement_id: 7)

    assert_requested delete
    assert_equal "del_1", accepted.operation_id
    assert_raises(BoatClient::Refused) { @client.delete_sandbox("../limits", placement_id: 7) }
  end

  test "limits reads the account tier, start allowance and included hours" do
    stub_request(:get, "#{API}/limits").to_return(status: 200, body: {
      accessTier: "trial", canStart: true, currentLimits: { activeSandboxes: 2, creationRequestsPerDay: 75 },
      wallet: { balanceDollars: 0 }, planIncluded: { vmHoursRemaining: 555.4, periodEnd: "2026-11-19T15:59:50.000Z" }
    }.to_json)

    limits = @client.limits

    assert_equal "trial", limits.access_tier
    assert_equal 2, limits.max_active_sandboxes
    assert_equal 75, limits.starts_per_day
    assert_in_delta 555.4, limits.included_hours_remaining
  end

  test "an unreachable Boat on a read is a retryable error, not absence" do
    stub_request(:get, "#{API}/sandboxes/bx_23456789").to_raise(Errno::ECONNREFUSED)

    error = assert_raises(BoatClient::Error) { @client.find_sandbox("bx_23456789") }
    assert_equal "unavailable", error.code
    assert error.retryable?
  end

end

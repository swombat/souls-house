require "test_helper"
require "webmock/minitest"

class BoatClientTest < ActiveSupport::TestCase

  API = "https://boat.dev/api/v1".freeze
  LABELS = { "souls-house/managed" => "true", "souls-house/placement" => "7", "souls-house/operation" => "bop-1" }.freeze

  setup do
    WebMock.disable_net_connect!
    @client = BoatClient.new(token: "synthetic-token", allowed_sizes: %w[small])
  end

  def sandbox_json(id: "bx_23456789", state: "ready", labels: LABELS)
    { "id" => id, "name" => "souls-house-bop-1", "state" => state, "type" => "small", "error" => nil,
      "stoppedAt" => nil, "dataExpiredAt" => nil, "labels" => labels }
  end

  def create!(**overrides)
    @client.create_sandbox(**{ idempotency_key: "bop-1", name: "souls-house-bop-1", placement_id: 7,
                               operation_id: "bop-1", size: "small", setup_script: "echo runner" }.merge(overrides))
  end

  def stub_find(id: "bx_23456789", **json)
    stub_request(:get, "#{API}/sandboxes/#{id}").to_return(status: 200, body: { sandbox: sandbox_json(id:, **json) }.to_json)
  end

  test "creates a labelled, no-env sandbox under the operation's idempotency key" do
    stub = stub_request(:post, "#{API}/sandboxes")
      .with(headers: { "Authorization" => "Bearer synthetic-token", "Idempotency-Key" => "bop-1" }) do |request|
        body = JSON.parse(request.body)
        body["noEnv"] == true && body["type"] == "small" && !body.key?("size") && body["labels"] == LABELS &&
          body["setupScript"] == "echo runner" && body["ttlSeconds"] == 1800 && !body.key?("autoStopSeconds")
      end
      .to_return(status: 202, body: { sandbox: sandbox_json(state: "provisioning") }.to_json)

    sandbox = create!(ttl_seconds: 1800)

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
      { sandbox: sandbox_json.merge("id" => "") }, { ok: true } ].each do |body|
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
    stub_request(:post, "#{API}/sandboxes").to_return(status: 503, body: { code: "no_ready_machine" }.to_json)
    assert_raises(BoatClient::CapacityUnavailable) { create! }

    stub_request(:post, "#{API}/sandboxes").to_return(status: 429, body: { code: "active_sandbox_limit" }.to_json)
    assert_raises(BoatClient::CapacityUnavailable) { create! }
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
      .to_return(status: 202, body: { sandbox: sandbox_json(state: "provisioning") }.to_json)
    stop = stub_request(:post, "#{API}/sandboxes/bx_23456789/stop")
      .to_return(status: 202, body: { sandbox: sandbox_json(state: "archiving") }.to_json)

    assert @client.resume_sandbox("bx_23456789", placement_id: 7).transitional?
    assert_equal "archiving", @client.stop_sandbox("bx_23456789", placement_id: 7).state
    assert_requested resume
    assert_requested stop

    assert_raises(BoatClient::Refused) { @client.stop_sandbox("bx_23456789", placement_id: 8) }

    stub_find(labels: { "souls-house/placement" => "7" })
    assert_raises(BoatClient::Refused) { @client.resume_sandbox("bx_23456789", placement_id: 7) }
    assert_requested resume, times: 1
    assert_requested stop, times: 1
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

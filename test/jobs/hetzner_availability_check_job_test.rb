require "test_helper"
require "webmock/minitest"

class HetznerAvailabilityCheckJobTest < ActiveJob::TestCase

  API = "https://api.hetzner.cloud/v1/server_types".freeze

  setup do
    WebMock.disable_net_connect!
    @client = HetznerCloudClient.new(token: "synthetic-token", allowed_server_types: [], allowed_locations: [])
  end

  teardown { WebMock.reset! }

  def run_check
    HetznerCloudClient.stub(:from_credentials, @client) { HetznerAvailabilityCheckJob.perform_now }
  end

  def type_json(name, available)
    { "name" => name, "locations" => %w[fsn1 nbg1 hel1].map { |loc| { "name" => loc, "available" => available.include?(loc) } } }
  end

  def respond(types)
    stub_request(:get, API).with(query: { per_page: "50" }, headers: { "Authorization" => "Bearer synthetic-token" })
      .to_return(status: 200, body: { server_types: types, meta: { pagination: { page: 1, next_page: nil } } }.to_json)
  end

  test "records one row per tracked type and location, available where Hetzner says so" do
    respond(HetznerAvailabilitySample::TYPES.map { |name| type_json(name, name == "cax11" ? %w[hel1] : []) } +
      [ type_json("cpx22", %w[fsn1 nbg1 hel1]) ])

    at = Time.zone.parse("2026-11-13 09:30:00")
    travel_to(at) { run_check }

    assert_equal 24, HetznerAvailabilitySample.count
    assert_equal [ [ "cax11", "hel1" ] ], HetznerAvailabilitySample.where(available: true).pluck(:server_type, :location)
    assert_equal [ at ], HetznerAvailabilitySample.distinct.pluck(:checked_at)
    assert_not HetznerAvailabilitySample.exists?(server_type: "cpx22")
    assert HetznerAvailabilitySample.where(error: nil).count == 24
  end

  test "everything unavailable is recorded as checked and unavailable" do
    respond(HetznerAvailabilitySample::TYPES.map { |name| type_json(name, []) })

    run_check

    assert_equal 24, HetznerAvailabilitySample.where(available: false).count
  end

  test "an API error is recorded as a check that could not be made, not as unavailable" do
    stub_request(:get, API).with(query: { per_page: "50" })
      .to_return(status: 503, body: { error: { code: "unavailable", message: "busy" } }.to_json)

    run_check

    assert_equal HetznerAvailabilitySample::TYPES.sort, HetznerAvailabilitySample.pluck(:server_type).sort
    assert HetznerAvailabilitySample.all.all? { |row| row.available.nil? && row.error == "unavailable" }
  end

  test "a timeout is recorded the same way, once, without retrying" do
    stub = stub_request(:get, API).with(query: { per_page: "50" }).to_timeout

    run_check

    assert_requested stub, times: 1
    assert_equal [ "unavailable" ], HetznerAvailabilitySample.distinct.pluck(:error)
    assert_enqueued_jobs 0
  end

  test "a tracked type Hetzner no longer lists is marked not_listed" do
    respond(HetznerAvailabilitySample::TYPES.without("cx53").map { |name| type_json(name, []) })

    run_check

    row = HetznerAvailabilitySample.find_by!(server_type: "cx53")
    assert_equal [ nil, nil, "not_listed" ], [ row.location, row.available, row.error ]
  end

end

require "test_helper"
require "webmock/minitest"

class HetznerCloudClientTest < ActiveSupport::TestCase

  API = "https://api.hetzner.cloud/v1".freeze

  setup do
    WebMock.disable_net_connect!
    @client = HetznerCloudClient.new(token: "synthetic-token", allowed_server_types: %w[cx23 cx33], allowed_locations: %w[nbg1])
  end

  def server_json(id: 42, labels: { "souls-house/managed" => "true", "souls-house/placement" => "p-7" }, status: "running")
    {
      "id" => id, "name" => "resident-p-7", "status" => status,
      "server_type" => { "name" => "cx23" },
      "datacenter" => { "location" => { "name" => "nbg1" } },
      "public_net" => { "ipv4" => { "ip" => "203.0.113.4" }, "ipv6" => { "ip" => "2001:db8::/64" } },
      "labels" => labels
    }
  end

  def create!(**overrides)
    @client.create_server(**{ name: "resident-p-7", placement_id: "p-7", server_type: "cx23", location: "nbg1",
                              image: "debian-13", ssh_keys: ["house-runner"] }.merge(overrides))
  end

  test "creates a labelled server and never returns the root password" do
    stub = stub_request(:post, "#{API}/servers")
      .with(headers: { "Authorization" => "Bearer synthetic-token" }) do |request|
        body = JSON.parse(request.body)
        body["server_type"] == "cx23" && body["ssh_keys"] == ["house-runner"] &&
          body["labels"] == { "souls-house/managed" => "true", "souls-house/placement" => "p-7" }
      end
      .to_return(status: 201, body: { server: server_json(status: "initializing"), action: {}, root_password: "leak-me" }.to_json)

    server = create!

    assert_requested stub
    assert_equal 42, server.id
    assert_equal "initializing", server.status
    assert_equal "203.0.113.4", server.ipv4
    assert server.managed?
    assert_not_includes server.inspect, "leak-me"
    assert_equal %i[id name status server_type location ipv4 ipv6 labels], HetznerCloudClient::Server.members
  end

  test "refuses unconfigured, off-allowlist and keyless creates before any request" do
    unconfigured = HetznerCloudClient.new(token: nil, allowed_server_types: %w[cx23], allowed_locations: %w[nbg1])
    assert_raises(HetznerCloudClient::NotConfigured) do
      unconfigured.create_server(name: "r", placement_id: "p", server_type: "cx23", location: "nbg1", image: "debian-13", ssh_keys: ["k"])
    end
    assert_raises(HetznerCloudClient::Refused) { create!(server_type: "ccx63") }
    assert_raises(HetznerCloudClient::Refused) { create!(location: "ash") }
    assert_raises(HetznerCloudClient::Refused) { create!(ssh_keys: []) }
    assert_raises(HetznerCloudClient::Refused) { create!(placement_id: nil) }
    assert_not_requested :any, /api\.hetzner\.cloud/
  end

  test "a create that times out is reported as outcome unknown, not retried" do
    stub = stub_request(:post, "#{API}/servers").to_timeout

    error = assert_raises(HetznerCloudClient::CreateOutcomeUnknown) { create! }

    assert_requested stub, times: 1
    assert_not error.retryable?
  end

  test "a create that fails server-side is outcome unknown and not retryable" do
    stub_request(:post, "#{API}/servers").to_return(status: 503, body: { error: { code: "unavailable", message: "busy" } }.to_json)

    error = assert_raises(HetznerCloudClient::CreateOutcomeUnknown) { create! }

    assert_equal 503, error.status
    assert_not error.retryable?
  end

  test "a dropped connection or a malformed success on create is outcome unknown" do
    stub_request(:post, "#{API}/servers").to_raise(EOFError).then
      .to_return({ status: 201, body: {}.to_json },
                 { status: 201, body: { server: nil }.to_json },
                 { status: 201, body: { server: { name: "no-id" } }.to_json },
                 { status: 201, body: "not json" })

    5.times { assert_raises(HetznerCloudClient::CreateOutcomeUnknown) { create! } }
  end

  test "classifies stock, name collision and rate limit errors" do
    stub_request(:post, "#{API}/servers").to_return(
      { status: 412, body: { error: { code: "resource_unavailable", message: "no stock" } }.to_json },
      { status: 409, body: { error: { code: "uniqueness_error", message: "name taken" } }.to_json },
      { status: 429, body: { error: { code: "rate_limit_exceeded", message: "slow down" } }.to_json }
    )

    assert_raises(HetznerCloudClient::CapacityUnavailable) { create! }
    assert_raises(HetznerCloudClient::NameTaken) { create! }
    limited = assert_raises(HetznerCloudClient::Error) { create! }
    assert limited.retryable?
    assert_equal 429, limited.status
  end

  test "errors carry the code and status, not the token or upstream message" do
    stub_request(:get, "#{API}/servers/42")
      .to_return(status: 401, body: { error: { code: "unauthorized", message: "token synthetic-token rejected" } }.to_json)

    error = assert_raises(HetznerCloudClient::Error) { @client.find_server(42) }

    assert_equal "Hetzner Cloud unauthorized (HTTP 401)", error.message
  end

  test "find returns nil for a missing server and finds by placement label" do
    stub_request(:get, "#{API}/servers/9").to_return(status: 404, body: { error: { code: "not_found", message: "nope" } }.to_json)
    stub_request(:get, "#{API}/servers")
      .with(query: { label_selector: "souls-house/managed=true,souls-house/placement=p-7" })
      .to_return(status: 200, body: { servers: [server_json], meta: {} }.to_json)

    assert_nil @client.find_server(9)
    assert_equal [42], @client.find_by_placement("p-7").map(&:id)
  end

  test "delete reports acceptance, not completion, and is safe to repeat" do
    stub_request(:get, "#{API}/servers/42").to_return(
      { status: 200, body: { server: server_json }.to_json },
      { status: 404, body: { error: { code: "not_found", message: "gone" } }.to_json }
    )
    delete = stub_request(:delete, "#{API}/servers/42").to_return(status: 200, body: { action: { id: 77, status: "running" } }.to_json)

    accepted = @client.delete_server(42, placement_id: "p-7")

    assert_equal HetznerCloudClient::DeleteAccepted.new(server_id: 42, action_id: 77, action_status: "running"), accepted
    assert_equal :already_absent, @client.delete_server(42, placement_id: "p-7")
    assert_requested delete, times: 1
  end

  test "delete refuses a server the house did not create" do
    stub_request(:get, "#{API}/servers/42").to_return(status: 200, body: { server: server_json(labels: { "role" => "mail" }) }.to_json)

    assert_raises(HetznerCloudClient::Refused) { @client.delete_server(42, placement_id: "p-7") }
    assert_not_requested :delete, /api\.hetzner\.cloud/
  end

  test "delete refuses another resident's managed server" do
    other = { "souls-house/managed" => "true", "souls-house/placement" => "p-8" }
    stub_request(:get, "#{API}/servers/42").to_return(status: 200, body: { server: server_json(labels: other) }.to_json)

    assert_raises(HetznerCloudClient::Refused) { @client.delete_server(42, placement_id: "p-7") }
    assert_raises(HetznerCloudClient::Refused) { @client.delete_server(42, placement_id: nil) }
    assert_not_requested :delete, /api\.hetzner\.cloud/
  end

  test "delete refuses when the returned server is not the one requested" do
    stub_request(:get, "#{API}/servers/42").to_return(status: 200, body: { server: server_json(id: 43) }.to_json)

    assert_raises(HetznerCloudClient::Refused) { @client.delete_server(42, placement_id: "p-7") }
    assert_not_requested :delete, /api\.hetzner\.cloud/
  end

end

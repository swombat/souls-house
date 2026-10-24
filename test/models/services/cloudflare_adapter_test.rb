require "test_helper"
require "webmock/minitest"

class Services::CloudflareAdapterTest < ActiveSupport::TestCase

  API = "https://api.cloudflare.com/client/v4".freeze

  setup do
    @adapter = Services::CloudflareAdapter.new(Services::Definition.fetch("cloudflare"))
    @zones = {
      success: true,
      result: [
        { id: "z2", name: "b.test", account: { id: "acc", name: "Acme" } },
        { id: "z1", name: "a.test", account: { id: "acc", name: "Acme" } }
      ]
    }
  end

  test "a user token: verified, then labelled with the zones it can see" do
    verify = stub_cf("/user/tokens/verify", { success: true, result: { id: "tok1", status: "active", expires_on: "2027-01-01T00:00:00Z" } })
    stub_cf("/zones?per_page=50&page=1", @zones)

    result = @adapter.connection_attributes(credentials: { "api_token" => " Bearer cf_secret " }, user: users(:user_1))

    assert_requested :get, "#{API}/user/tokens/verify", headers: { "Authorization" => "Bearer cf_secret" }
    assert_requested verify
    assert_equal "tok1", result[:external_subject_id]
    assert_equal "Acme", result[:external_identity]
    assert_equal "Cloudflare (Acme): a.test, b.test", result[:label]
    assert_equal({ "api_token" => "cf_secret" }, result[:credential_payload])
    metadata = result[:credential_metadata]
    assert_equal "user", metadata["token_kind"]
    assert_equal %w[a.test b.test], metadata["zones"]
    assert_equal({ "b.test" => "z2", "a.test" => "z1" }, metadata["zone_ids"])
    assert_equal "2027-01-01T00:00:00Z", metadata["token_expires_on"]
    assert_not_includes metadata.values.join(" "), "cf_secret"
  end

  test "an account-owned token fails the user check but counts when it can list zones" do
    stub_cf("/user/tokens/verify", { success: false, errors: [ { code: 1000, message: "Invalid API Token" } ] }, status: 401)
    stub_cf("/zones?per_page=50&page=1", @zones)

    result = @adapter.connection_attributes(credentials: { "api_token" => "cf_account" }, user: users(:user_1))

    assert_nil result[:external_subject_id]
    assert_equal "account", result.dig(:credential_metadata, "token_kind")
    assert_equal "Cloudflare (Acme): a.test, b.test", result[:label]
  end

  test "a token Cloudflare rejects everywhere is refused" do
    stub_cf("/user/tokens/verify", { success: false }, status: 401)
    stub_cf("/zones?per_page=50&page=1", { success: false }, status: 403)

    error = assert_raises(Services::CloudflareAdapter::Error) do
      @adapter.connection_attributes(credentials: { "api_token" => "nope" }, user: users(:user_1))
    end

    assert_equal "Cloudflare rejected this API token", error.message
  end

  test "an unverifiable token that sees no zones is refused with the permission to add" do
    stub_cf("/user/tokens/verify", { success: false }, status: 401)
    stub_cf("/zones?per_page=50&page=1", { success: true, result: [] })

    error = assert_raises(Services::CloudflareAdapter::Error) do
      @adapter.connection_attributes(credentials: { "api_token" => "cf_blind" }, user: users(:user_1))
    end

    assert_match "Zone → Zone → Read", error.message
  end

  test "a verified user token without zone read still connects, and says so in its label" do
    stub_cf("/user/tokens/verify", { success: true, result: { id: "tok2", status: "active" } })
    stub_cf("/zones?per_page=50&page=1", { success: false }, status: 403)

    result = @adapter.connection_attributes(credentials: { "api_token" => "cf_dns_only" }, user: users(:user_1))

    assert_equal "Cloudflare: no zones visible", result[:label]
    assert_equal [], result.dig(:credential_metadata, "zones")
  end

  test "a disabled or expired token is refused, and a server error is not mistaken for a rejection" do
    stub_cf("/user/tokens/verify", { success: true, result: { id: "tok3", status: "disabled" } })
    assert_match "is disabled, not active",
                 assert_raises(Services::CloudflareAdapter::Error) { @adapter.connection_attributes(credentials: { "api_token" => "t" }, user: users(:user_1)) }.message

    WebMock.reset!
    stub_request(:get, "#{API}/user/tokens/verify").to_return(status: 500, body: "")
    assert_equal "Cloudflare validation failed (500)",
                 assert_raises(Services::CloudflareAdapter::Error) { @adapter.connection_attributes(credentials: { "api_token" => "t" }, user: users(:user_1)) }.message
  end

  test "follows every page of zones, and says when it stopped short" do
    stub_cf("/user/tokens/verify", { success: true, result: { id: "tok4", status: "active" } })
    stub_cf("/zones?per_page=50&page=1", { success: true, result: [ { id: "z1", name: "a.test" } ], result_info: { page: 1, total_pages: 2 } })
    stub_cf("/zones?per_page=50&page=2", { success: true, result: [ { id: "z2", name: "b.test" } ], result_info: { page: 2, total_pages: 2 } })

    result = @adapter.connection_attributes(credentials: { "api_token" => "t" }, user: users(:user_1))
    assert_equal %w[a.test b.test], result.dig(:credential_metadata, "zones")
    assert result.dig(:credential_metadata, "zones_complete")

    WebMock.reset!
    stub_cf("/user/tokens/verify", { success: true, result: { id: "tok4", status: "active" } })
    stub_request(:get, "#{API}/zones").with(query: hash_including("per_page" => "50")).to_return do |request|
      page = request.uri.query_values["page"].to_i
      { status: 200, headers: { "Content-Type" => "application/json" },
        body: { success: true, result: [ { id: "z#{page}", name: "zone#{format('%02d', page)}.test" } ], result_info: { page: page, total_pages: 30 } }.to_json }
    end

    result = @adapter.connection_attributes(credentials: { "api_token" => "t" }, user: users(:user_1))
    assert_equal Services::CloudflareAdapter::ZONE_PAGES, result.dig(:credential_metadata, "zones").size
    assert_not result.dig(:credential_metadata, "zones_complete")
    assert_equal "Cloudflare: zone01.test, zone02.test, zone03.test and more than 17 others", result[:label]
  end

  test "requires a token" do
    assert_equal "Cloudflare API token is required",
                 assert_raises(Services::CloudflareAdapter::Error) { @adapter.connection_attributes(credentials: {}, user: users(:user_1)) }.message
  end

  private

  def stub_cf(path, body, status: 200)
    stub_request(:get, "#{API}#{path}")
      .to_return(status: status, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

end

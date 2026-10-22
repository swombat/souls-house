require "test_helper"
require "webmock/minitest"

class Services::GhostAdapterTest < ActiveSupport::TestCase

  KEY_ID = "6489f0c2a1b2c3d4e5f60718".freeze
  SECRET = ("ab" * 32).freeze
  KEY = "#{KEY_ID}:#{SECRET}".freeze
  API = "https://blog.example.com/ghost/api/admin".freeze

  setup do
    @adapter = Services::GhostAdapter.new(Services::Definition.fetch("ghost"))
    @site = { "site" => { "title" => "Lume writes", "url" => "https://blog.example.com/", "version" => "5.101" } }
  end

  def public_dns(&)
    @adapter.stub(:resolve_addresses, ->(_host) { [ "93.184.216.34" ] }, &)
  end

  def stub_site(status: 200, posts_status: 200)
    site = stub_request(:get, "#{API}/site/").to_return(status:, body: @site.to_json, headers: { "Content-Type" => "application/json" })
    posts = stub_request(:get, "#{API}/posts/?limit=1&fields=id")
      .to_return(status: posts_status, body: { posts: [] }.to_json, headers: { "Content-Type" => "application/json" })
    [ site, posts ]
  end

  test "proves the key on the site and keeps the key out of the metadata" do
    site, posts = stub_site

    result = public_dns do
      @adapter.connection_attributes(credentials: { "api_url" => " blog.example.com/ghost/ ", "admin_api_key" => " #{KEY} " }, user: users(:user_1))
    end

    assert_requested site
    assert_requested posts
    assert_equal "Ghost (Lume writes)", result[:label]
    assert_equal "https://blog.example.com", result[:external_identity]
    assert_equal "blog.example.com:#{KEY_ID}", result[:external_subject_id]
    assert_equal({ "admin_api_key" => KEY }, result[:credential_payload])
    assert_equal "https://blog.example.com/ghost/api/admin", result.dig(:credential_metadata, "api_base")
    assert_equal "https://blog.example.com", result.dig(:credential_metadata, "api_url")
    assert_equal "static", result.dig(:credential_metadata, "credential_strategy")
    assert_match "send newsletters", result.dig(:credential_metadata, "authority_summary")
    assert_not_includes result[:credential_metadata].values.join(" "), SECRET
    assert_not_includes result[:credential_fingerprint], SECRET
  end

  test "signs every call with a five-minute admin token Ghost can verify" do
    stub_site
    seen = []
    WebMock.after_request { |request, _response| seen << request.headers }

    public_dns do
      @adapter.connection_attributes(credentials: { "api_url" => "https://blog.example.com", "admin_api_key" => KEY }, user: users(:user_1))
    end

    assert_equal 2, seen.size
    seen.each do |headers|
      assert_equal "v5.0", headers["Accept-Version"]
      scheme, token = headers["Authorization"].split(" ", 2)
      assert_equal "Ghost", scheme
      header, payload, signature = token.split(".")
      assert_equal({ "alg" => "HS256", "typ" => "JWT", "kid" => KEY_ID }, JSON.parse(Base64.urlsafe_decode64(header)))
      claims = JSON.parse(Base64.urlsafe_decode64(payload))
      assert_equal "/admin/", claims["aud"]
      assert_equal 300, claims["exp"] - claims["iat"]
      expected = Base64.urlsafe_encode64(OpenSSL::HMAC.digest("SHA256", [ SECRET ].pack("H*"), "#{header}.#{payload}"), padding: false)
      assert_equal expected, signature
    end
  ensure
    WebMock::CallbackRegistry.reset
  end

  test "a key Ghost refuses is refused" do
    stub_site(posts_status: 401)

    error = assert_raises(Services::GhostAdapter::Error) do
      public_dns { @adapter.connection_attributes(credentials: { "api_url" => "https://blog.example.com", "admin_api_key" => KEY }, user: users(:user_1)) }
    end

    assert_equal "blog.example.com rejected this Admin API key", error.message
  end

  test "a redirect names where it goes instead of following it" do
    stub_request(:get, "#{API}/site/").to_return(status: 301, headers: { "Location" => "https://www.blog.example.com/ghost/api/admin/site/" })

    error = assert_raises(Services::GhostAdapter::Error) do
      public_dns { @adapter.connection_attributes(credentials: { "api_url" => "https://blog.example.com", "admin_api_key" => KEY }, user: users(:user_1)) }
    end

    assert_match "redirects to www.blog.example.com", error.message
  end

  test "refuses a content API key and other shapes before calling anyone" do
    [ "0123456789abcdef01234567", "#{KEY_ID}:not-hex", "" ].each do |key|
      assert_raises(Services::GhostAdapter::Error) do
        @adapter.connection_attributes(credentials: { "api_url" => "https://blog.example.com", "admin_api_key" => key }, user: users(:user_1))
      end
    end
    assert_not_requested :any, /example\.com/
  end

  test "only calls https on public addresses" do
    error = assert_raises(Services::GhostAdapter::Error) do
      @adapter.connection_attributes(credentials: { "api_url" => "http://blog.example.com", "admin_api_key" => KEY }, user: users(:user_1))
    end
    assert_match "https://", error.message

    [ "127.0.0.1", "10.1.2.3", "100.101.102.103", "169.254.169.254", "::1", "::ffff:192.168.1.1", "fd00::1" ].each do |address|
      @adapter.stub(:resolve_addresses, ->(_host) { [ "93.184.216.34", address ] }) do
        error = assert_raises(Services::GhostAdapter::Error) do
          @adapter.connection_attributes(credentials: { "api_url" => "https://blog.example.com", "admin_api_key" => KEY }, user: users(:user_1))
        end
        assert_equal "blog.example.com is not on the public internet", error.message, address
      end
    end
    assert_not_requested :any, /example\.com/
  end

  test "pins the request to the address it checked" do
    stub_site
    pinned = []
    original = Net::HTTP.instance_method(:ipaddr=)
    Net::HTTP.define_method(:ipaddr=) { |address| pinned << address; original.bind_call(self, address) }

    public_dns do
      @adapter.connection_attributes(credentials: { "api_url" => "https://blog.example.com", "admin_api_key" => KEY }, user: users(:user_1))
    end

    assert_equal [ "93.184.216.34", "93.184.216.34" ], pinned
  ensure
    Net::HTTP.define_method(:ipaddr=, original)
  end

  test "normalizes the API URL Ghost shows, keeping a subdirectory install" do
    {
      "yourblog.ghost.io" => "https://yourblog.ghost.io",
      "https://Example.com/" => "https://example.com",
      "https://example.com/blog/ghost/#/settings" => "https://example.com/blog",
      "https://example.com:8443/ghost/api/admin/" => "https://example.com:8443"
    }.each do |input, expected|
      assert_equal expected, Services::GhostAdapter.normalize_api_url(input), input
    end
    assert_raises(Services::GhostAdapter::Error) { Services::GhostAdapter.normalize_api_url("https://user:pw@example.com") }
  end

end

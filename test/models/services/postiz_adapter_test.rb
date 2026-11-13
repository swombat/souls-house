require "test_helper"
require "webmock/minitest"

class Services::PostizAdapterTest < ActiveSupport::TestCase
  setup do
    @adapter = Services::Definition.fetch("postiz").adapter
    @base = Services::PostizAdapter::DEFAULT_BASE
    @connection = ServiceConnection.new(credential_payload_hash: { "api_base" => @base, "api_token" => "secret" })
  end

  def public_dns(&block)
    @adapter.stub(:resolve_addresses, [ "93.184.216.34" ], &block)
  end

  def channels
    stub_request(:get, "#{@base}/integrations").with(headers: { "Authorization" => "secret" })
      .to_return(body: [ { id: "c1", name: "Channel", identifier: "x", token: "leaked",
                          refreshToken: "leaked", nested: { secret: "leaked" } } ].to_json)
  end

  test "allowlists channels and keeps credentials out of metadata" do
    channels
    public_dns do
      result = @adapter.list_channels(@connection)
      assert_equal [ { "id" => "c1", "name" => "Channel", "identifier" => "x", "draft_supported" => true } ], result
      attributes = @adapter.connection_attributes(credentials: { "api_token" => "secret" }, user: users(:user_1))
      assert_equal "secret", attributes.dig(:credential_payload, "api_token")
      assert_not_includes attributes[:credential_metadata].to_json, "secret"
    end
  end

  test "constructs draft payload and sanitizes its response" do
    channels
    post = stub_request(:post, "#{@base}/posts").with do |request|
      body = JSON.parse(request.body)
      body["type"] == "draft" && body["date"].present? && body["shortLink"] == false && body["tags"] == [] &&
        body.dig("posts", 0, "settings") == { "__type" => "x", "who_can_reply_post" => "everyone" } &&
        body.dig("posts", 0, "value", 0) == { "content" => "Hello", "image" => [] }
    end.to_return(body: [ { id: "draft1", token: "leaked" } ].to_json)
    public_dns do
      assert_equal [ { "id" => "draft1" } ], @adapter.create_draft(@connection, channel_id: "c1", content: "Hello")
    end
    assert_requested post, times: 1
  end

  test "rejects nonpublic addresses including mapped IPv4 and mixed DNS" do
    %w[127.0.0.1 10.1.2.3 169.254.169.254 ::1 ::ffff:127.0.0.1 2001:db8::1].each do |address|
      @adapter.stub(:resolve_addresses, [ "93.184.216.34", address ]) do
        assert_raises(Services::AdapterError) { @adapter.list_channels(@connection) }
      end
    end
    assert_not_requested :any, /api.postiz.com/
  end

  test "unsupported provider is marked and rejected before a draft POST" do
    %w[youtube reddit unknown-provider].each do |provider|
      stub_request(:get, "#{@base}/integrations")
        .to_return(body: [ { id: "c1", identifier: provider, draft_supported: true } ].to_json)
      public_dns do
        assert_equal false, @adapter.list_channels(@connection).first["draft_supported"]
        error = assert_raises(Services::AdapterError) do
          @adapter.create_draft(@connection, channel_id: "c1", content: "Hello")
        end
        assert_includes error.message, "not supported"
      end
    end
    assert_not_requested :post, "#{@base}/posts"
  end

  test "LinkedIn drafts use its optional-only settings contract" do
    stub_request(:get, "#{@base}/integrations")
      .to_return(body: [ { id: "c1", identifier: "linkedin" } ].to_json)
    post = stub_request(:post, "#{@base}/posts").with do |request|
      body = JSON.parse(request.body)
      body["type"] == "draft" && body.dig("posts", 0, "settings") == { "__type" => "linkedin" }
    end.to_return(body: { postId: "draft1" }.to_json)
    public_dns { @adapter.create_draft(@connection, channel_id: "c1", content: "Hello") }
    assert_requested post, times: 1
  end

  test "does not follow redirects or expose error bodies" do
    stub_request(:get, "#{@base}/integrations").to_return(status: 302,
      headers: { "Location" => "https://evil.example/" }, body: "leaked")
    public_dns do
      error = assert_raises(Services::AdapterError) { @adapter.list_channels(@connection) }
      assert_not_includes error.message, "leaked"
    end
    assert_not_requested :any, /evil.example/
  end

  test "refuses unsafe base URLs" do
    %w[http://example.com https://user:secret@example.com https://example.com/?token=x https://example.com/#x].each do |base|
      assert_raises(Services::AdapterError) do
        @adapter.connection_attributes(credentials: { "api_base" => base, "api_token" => "secret" }, user: nil)
      end
    end
  end

  test "a failed POST is not retried" do
    channels
    post = stub_request(:post, "#{@base}/posts").to_timeout
    public_dns do
      assert_raises(Services::AdapterError) { @adapter.create_draft(@connection, channel_id: "c1", content: "Hello") }
    end
    assert_requested post, times: 1
  end

  test "selfhost uses its complete base path" do
    base = "https://social.mexzungu.com/api/public/v1"
    call = stub_request(:get, "#{base}/integrations").to_return(body: "[]")
    public_dns do
      result = @adapter.connection_attributes(
        credentials: { "api_base" => base, "api_token" => "secret" }, user: nil)
      assert_equal base, result.dig(:credential_payload, "api_base")
    end
    assert_requested call
  end

  test "accepts object receipts and refuses ambiguous malformed or secret-bearing IDs" do
    channels
    post = stub_request(:post, "#{@base}/posts")
    public_dns do
      post.to_return(body: { postId: "draft1", integration: { token: "leaked" } }.to_json)
      assert_equal [ { "postId" => "draft1" } ], @adapter.create_draft(@connection, channel_id: "c1", content: "Hello")
      [ [], {}, { id: { secret: "leaked" } }, [ { postId: "" } ], "wrong" ].each do |receipt|
        post.to_return(body: receipt.to_json)
        error = assert_raises(Services::AdapterError) do
          @adapter.create_draft(@connection, channel_id: "c1", content: "Hello")
        end
        assert_includes error.message, "outcome unknown"
        assert_not_includes error.message, "leaked"
      end
    end
  end

  test "transport pins checked address disables proxies and disables retries" do
    http = Net::HTTP.new("api.postiz.com", 443, nil)
    request = stub_request(:get, "#{@base}/integrations").to_return(body: "[]")
    factory = lambda do |host, port, proxy|
      assert_equal "api.postiz.com", host
      assert_equal 443, port
      assert_nil proxy
      http
    end
    Net::HTTP.stub(:new, factory) do
      public_dns { assert_equal [], @adapter.list_channels(@connection) }
    end
    assert_equal "93.184.216.34", http.ipaddr
    assert_equal 0, http.max_retries
    assert http.use_ssl?
    assert_not http.proxy?
    assert_requested request
  end
end

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

  def signed_media(path, id: "m1", connection_id: @connection.id)
    token = Rails.application.message_verifier("postiz-media").generate(
      { "connection_id" => connection_id, "id" => id, "path" => path }, purpose: "postiz-media")
    { "id" => id, "path" => path, "upload_token" => token }
  end

  def tiktok_settings
    { "privacy_level" => "SELF_ONLY", "duet" => false, "stitch" => false,
      "comment" => false, "autoAddMusic" => "no", "brand_content_toggle" => false,
      "brand_organic_toggle" => false, "content_posting_method" => "DIRECT_POST" }
  end

  def provider_channel(provider)
    stub_request(:get, "#{@base}/integrations")
      .to_return(body: [ { id: "c1", identifier: provider } ].to_json)
  end

  test "allowlists channels and keeps credentials out of metadata" do
    channels
    public_dns do
      result = @adapter.list_channels(@connection)
      assert_equal [ { "id" => "c1", "name" => "Channel", "identifier" => "x", "draft_supported" => true, "post_supported" => true, "media_required" => false } ], result
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

  test "publishing requires explicit connection opt in" do
    channels
    public_dns do
      error = assert_raises(Services::AdapterError) do
        @adapter.create_post(@connection, channel_id: "c1", content: "Hello", mode: "publish_now")
      end
      assert_includes error.message, "not enabled"
      attrs = @adapter.connection_attributes(credentials: { "api_token" => "secret", "publishing" => "enabled" }, user: nil)
      assert_equal true, attrs.dig(:credential_metadata, "publishing_enabled")
      attrs = @adapter.connection_attributes(credentials: { "api_token" => "secret" }, user: nil)
      assert_equal false, attrs.dig(:credential_metadata, "publishing_enabled")
      assert_raises(Services::AdapterError) do
        @adapter.connection_attributes(credentials: { "api_token" => "secret", "publishing" => "yes" }, user: nil)
      end
    end
    assert_not_requested :post, "#{@base}/posts"
  end

  test "constructs scheduled provider posts and rejects unsafe options" do
    @connection.id = 123
    @connection.credential_metadata = { "publishing_enabled" => true }
    stub_request(:get, "#{@base}/integrations").to_return(body: [{ id: "c1", identifier: "instagram-standalone" }].to_json)
    post = stub_request(:post, "#{@base}/posts").with do |request|
      body = JSON.parse(request.body)
      body["type"] == "schedule" && body.dig("posts", 0, "settings") == { "__type" => "instagram-standalone", "post_type" => "post" } &&
        body.dig("posts", 0, "value", 0, "image") == [{ "id" => "m1", "path" => "https://cdn.example/uploads/a.jpg" }]
    end.to_return(body: [{ id: "p1", token: "secret" }].to_json)
    public_dns do
      path = "https://cdn.example/uploads/a.jpg"
      token = Rails.application.message_verifier("postiz-media").generate(
        { "connection_id" => @connection.id, "id" => "m1", "path" => path }, purpose: "postiz-media")
      args = { channel_id: "c1", content: "Hello", mode: "scheduled", scheduled_at: (Time.now + 3600).utc.iso8601,
        settings: { "post_type" => "post" }, media: [{ "id" => "m1", "path" => path, "upload_token" => token }] }
      assert_equal [{ "id" => "p1" }], @adapter.create_post(@connection, **args)
      assert_raises(Services::AdapterError) { @adapter.create_post(@connection, **args.merge(scheduled_at: "2099-01-01T12:00:00")) }
      assert_raises(Services::AdapterError) { @adapter.create_post(@connection, **args.merge(media: [])) }
      assert_raises(Services::AdapterError) { @adapter.create_post(@connection, **args.merge(settings: { "post_type" => "post", "evil" => true })) }
      assert_raises(Services::AdapterError) { @adapter.create_post(@connection, **args.merge(media: [{ "id" => "m", "path" => "http://127.0.0.1/a.jpg" }])) }
      assert_raises(Services::AdapterError) { @adapter.create_post(@connection, **args.merge(media: [{ "id" => "m1", "path" => "https://evil.example/a.jpg", "upload_token" => token }])) }
    end
    assert_requested post, times: 1
  end

  test "disabled channels cannot receive drafts" do
    stub_request(:get, "#{@base}/integrations").to_return(body: [{ id: "c1", identifier: "x", disabled: true }].to_json)
    public_dns do
      assert_raises(Services::AdapterError) { @adapter.create_draft(@connection, channel_id: "c1", content: "Hello") }
    end
    assert_not_requested :post, "#{@base}/posts"
  end

  test "publishes now and normalizes scheduled timezone to UTC" do
    @connection.credential_metadata = { "publishing_enabled" => true }
    channels
    now_post = stub_request(:post, "#{@base}/posts").with { |req|
      body = JSON.parse(req.body)
      body["type"] == "now" && body.dig("posts", 0, "integration", "id") == "c1"
    }.to_return(body: '[{"id":"now1"}]')
    schedule_post = stub_request(:post, "#{@base}/posts").with { |req|
      body = JSON.parse(req.body)
      body["type"] == "schedule" && body["date"] == "2099-01-02T11:30:00Z"
    }.to_return(body: '[{"postId":"scheduled1"}]')
    public_dns do
      assert_equal [ { "id" => "now1" } ], @adapter.create_post(@connection, channel_id: "c1", content: "Hello", mode: "publish_now")
      assert_equal [ { "postId" => "scheduled1" } ], @adapter.create_post(@connection, channel_id: "c1", content: "Hello",
        mode: "scheduled", scheduled_at: "2099-01-02T12:30:00+01:00")
    end
    assert_requested now_post, times: 1
    assert_requested schedule_post, times: 1
  end

  test "rejects missing invalid past and misplaced schedules before any network request" do
    @connection.credential_metadata = { "publishing_enabled" => true }
    [ nil, "", "2099-01-01T12:00:00", "not-a-date", "2099-13-01T12:00:00Z",
      "2000-01-01T00:00:00Z" ].each do |date|
      assert_raises(Services::AdapterError) do
        @adapter.create_post(@connection, channel_id: "c1", content: "Hello", mode: "scheduled", scheduled_at: date)
      end
    end
    %w[draft publish_now].each do |mode|
      assert_raises(Services::AdapterError) do
        @adapter.create_post(@connection, channel_id: "c1", content: "Hello", mode: mode, scheduled_at: "2099-01-01T12:00:00Z")
      end
    end
    assert_not_requested :any, /api.postiz.com/
  end

  test "all media providers construct allowlisted settings and signed media payloads" do
    @connection.id = 123
    image = signed_media("https://cdn.example/image.jpg")
    video = signed_media("https://cdn.example/video.mp4", id: "m2")
    cases = {
      "facebook" => [ { "post_type" => "post", "title" => "Video" }, video ],
      "instagram" => [ { "post_type" => "post" }, image ],
      "instagram-standalone" => [ { "post_type" => "story" }, video ],
      "tiktok" => [ tiktok_settings, video ],
      "tiktok-business" => [ tiktok_settings, image ],
      "youtube" => [ { "title" => "Title", "type" => "private" }, video ]
    }
    cases.each do |provider, (settings, media)|
      provider_channel(provider)
      expected_media = media.slice("id", "path")
      write = stub_request(:post, "#{@base}/posts").with do |req|
        body = JSON.parse(req.body)
        body["type"] == "draft" &&
          body.dig("posts", 0, "settings") == settings.merge("__type" => provider) &&
          body.dig("posts", 0, "value") == [ { "content" => "Hello", "image" => [ expected_media ] } ]
      end.to_return(body: '[{"id":"p1","token":"secret"}]')
      public_dns do
        assert_equal [ { "id" => "p1" } ], @adapter.create_post(@connection, channel_id: "c1", content: "Hello",
          mode: "draft", settings: settings, media: [ media ])
      end
      assert_requested write, times: 1
    end
  end

  test "provider settings reject missing required, invalid and unknown values" do
    @connection.id = 123
    image = signed_media("https://cdn.example/image.jpg")
    video = signed_media("https://cdn.example/video.mp4")
    cases = {
      "facebook" => [ video, [ { "post_type" => "reel" }, { "unknown" => true } ] ],
      "instagram" => [ image, [ {}, { "post_type" => "reel" }, { "post_type" => "post", "unknown" => true } ] ],
      "instagram-standalone" => [ image, [ {}, { "post_type" => "invalid" } ] ],
      "tiktok" => [ video, [ {}, tiktok_settings.merge("duet" => "false"), tiktok_settings.merge("privacy_level" => "everyone") ] ],
      "tiktok-business" => [ image, [ {}, tiktok_settings.merge("content_posting_method" => "invalid") ] ],
      "youtube" => [ video, [ {}, { "title" => "", "type" => "private" }, { "title" => "Title", "type" => "invalid" } ] ]
    }
    public_dns do
      cases.each do |provider, (media, settings_list)|
        provider_channel(provider)
        settings_list.each do |settings|
          assert_raises(Services::AdapterError, "#{provider}: #{settings.inspect}") do
            @adapter.create_post(@connection, channel_id: "c1", content: "Hello", mode: "draft", settings: settings, media: [ media ])
          end
        end
      end
    end
    assert_not_requested :post, "#{@base}/posts"
  end

  test "media receipts are bound to the connection and provider media combinations are checked" do
    @connection.id = 123
    image = signed_media("https://cdn.example/image.jpg")
    video = signed_media("https://cdn.example/video.mp4")
    foreign = signed_media("https://cdn.example/image.jpg", connection_id: 456)
    public_dns do
      provider_channel("instagram")
      assert_raises(Services::AdapterError) { @adapter.create_post(@connection, channel_id: "c1", content: "Hello", mode: "draft",
        settings: { "post_type" => "post" }, media: [ foreign ]) }
      assert_raises(Services::AdapterError) { @adapter.create_post(@connection, channel_id: "c1", content: "Hello", mode: "draft",
        settings: { "post_type" => "story" }, media: [ image, video ]) }
      provider_channel("youtube")
      [ [], [ image ], [ video, video ] ].each do |media|
        assert_raises(Services::AdapterError) { @adapter.create_post(@connection, channel_id: "c1", content: "Hello", mode: "draft",
          settings: { "title" => "Title", "type" => "private" }, media: media) }
      end
      provider_channel("tiktok")
      [ [], [ image, video ], [ video, video ] ].each do |media|
        assert_raises(Services::AdapterError) { @adapter.create_post(@connection, channel_id: "c1", content: "Hello", mode: "draft",
          settings: tiktok_settings, media: media) }
      end
      @connection.credential_metadata = { "publishing_enabled" => true }
      assert_raises(Services::AdapterError) { @adapter.create_post(@connection, channel_id: "c1", content: "Hello", mode: "publish_now",
        settings: tiktok_settings.merge("content_posting_method" => "UPLOAD"), media: [ video ]) }
    end
    assert_not_requested :post, "#{@base}/posts"
  end
end

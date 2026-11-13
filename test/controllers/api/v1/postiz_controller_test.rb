require "test_helper"

class Api::V1::PostizControllerTest < ActionDispatch::IntegrationTest
  setup do
    @agent = agents(:research_assistant)
    @user = users(:user_1)
    @key = ApiKey.generate_for(@user, name: "Postiz", agent: @agent)
    @headers = { "Authorization" => "Bearer #{@key.raw_token}" }
    @connection = @agent.account.service_connections.create!(
      connected_by_user: @user, provider: "postiz", management_scope: "personal",
      credential_kind: "token", status: "connected",
      credential_payload_hash: { "api_token" => "house-secret", "api_base" => Services::PostizAdapter::DEFAULT_BASE },
      credential_metadata: { "credential_strategy" => "postiz_proxy" }
    )
    @access = @agent.agent_service_accesses.create!(service_connection: @connection, enabled: true)
    @channels = api_v1_service_connection_postiz_channels_url(@connection.public_id)
    @drafts = api_v1_service_connection_postiz_drafts_url(@connection.public_id)
    @posts = api_v1_service_connection_postiz_posts_url(@connection.public_id)
    @uploads = api_v1_service_connection_postiz_uploads_url(@connection.public_id)
  end

  test "disabled grants and disconnected connections cannot call Postiz" do
    @access.update!(enabled: false)
    get @channels, headers: @headers
    assert_response :not_found
    @access.update!(enabled: true)
    @connection.update!(status: "revoked")
    get @channels, headers: @headers
    assert_response :conflict
  end

  test "human API keys cannot use either endpoint" do
    key = ApiKey.generate_for(@user, name: "Human Postiz")
    headers = { "Authorization" => "Bearer #{key.raw_token}" }
    get @channels, headers: headers
    assert_response :forbidden
    post @drafts, params: { channel_id: "c1", content: "Hello" }, headers: headers, as: :json
    assert_response :forbidden
  end

  test "other residents without a grant cannot use either endpoint across accounts" do
    %i[code_reviewer other_account_agent].each do |fixture|
      agent = agents(fixture)
      user = agent.account.users.first
      key = ApiKey.generate_for(user, name: "No Postiz grant", agent: agent)
      headers = { "Authorization" => "Bearer #{key.raw_token}" }
      get @channels, headers: headers
      assert_response :not_found
      post @drafts, params: { channel_id: "c1", content: "Hello" }, headers: headers, as: :json
      assert_response :not_found
    end
  end

  test "draft rejects extra provider authority" do
    %w[type date posts settings image].each do |field|
      post @drafts, params: { channel_id: "c1", content: "Hello", field => "publish" },
        headers: @headers, as: :json
      assert_response :unprocessable_entity
    end
  end

  test "manifest and browser props never contain the token" do
    manifest = @connection.runtime_credentials(agent: @agent)
    assert_equal %w[channels_endpoint drafts_endpoint posts_endpoint uploads_endpoint publishing_enabled], manifest.keys
    assert_equal false, manifest["publishing_enabled"]
    assert_not_includes manifest.to_json, "house-secret"
    assert_not_includes @connection.as_connection_json(current_user: @user).to_json, "house-secret"
    assert_includes @connection.runtime_entry(agent: @agent)["warnings"].last, "house-enforced"
  end

  test "granted resident can list channels and create a text draft" do
    adapter = Object.new
    adapter.define_singleton_method(:list_channels) { |_connection| [ { id: "c1" } ] }
    adapter.define_singleton_method(:create_draft) do |_connection, channel_id:, content:|
      raise "Wrong input" unless channel_id == "c1" && content == "Hello"
      [ { id: "draft1" } ]
    end
    Services::Definition.fetch("postiz").stub(:adapter, adapter) do
      get @channels, headers: @headers
      assert_response :ok
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_equal "c1", response.parsed_body.first["id"]
      post @drafts, params: { channel_id: "c1", content: "Hello" }, headers: @headers, as: :json
      assert_response :ok
      assert_equal "draft1", response.parsed_body.first["id"]
    end
  end

  test "new write endpoints enforce resident grants and connection status" do
    [@posts, @uploads].each do |endpoint|
      key = ApiKey.generate_for(@user, name: "Human")
      post endpoint, params: {}, headers: { "Authorization" => "Bearer #{key.raw_token}" }, as: :json
      assert_response :forbidden
      @access.update!(enabled: false)
      post endpoint, params: {}, headers: @headers, as: :json
      assert_response :not_found
      @access.update!(enabled: true)
      @connection.update!(status: "revoked")
      post endpoint, params: {}, headers: @headers, as: :json
      assert_response :conflict
      @connection.update!(status: "connected")
    end
  end

  test "post forwards only the explicit bounded contract" do
    adapter = Object.new
    calls = []
    adapter.define_singleton_method(:create_post) do |connection, **attributes|
      calls << attributes
      [{ "id" => "post1" }]
    end
    Services::Definition.fetch("postiz").stub(:adapter, adapter) do
      %w[draft publish_now scheduled].each do |mode|
        body = { channel_id: "c1", content: "Hello", mode: mode,
                 settings: { title: "Title" }, media: [{ id: "m1", path: "https://cdn.example/photo.png", upload_token: "signed" }] }
        body[:scheduled_at] = "2099-01-01T12:00:00+01:00" if mode == "scheduled"
        post @posts, params: body, headers: @headers, as: :json
        assert_response :ok
        assert_equal mode, calls.last[:mode]
        assert_equal({ "title" => "Title" }, calls.last[:settings])
        assert_equal "signed", calls.last[:media].first["upload_token"]
        assert_equal body[:scheduled_at], calls.last[:scheduled_at]
      end
      %w[type date posts integration __type].each do |field|
        post @posts, params: { channel_id: "c1", content: "Hello", mode: "draft", field => "extra" }, headers: @headers, as: :json
        assert_response :unprocessable_entity
      end
    end
    assert_equal 3, calls.size
  end

  test "upload rejects URLs and non-file JSON" do
    [{ url: "https://example.com/video.mp4" }, { file: "/etc/passwd" }, {}].each do |body|
      post @uploads, params: body, headers: @headers, as: :json
      assert_response :unprocessable_entity
    end
  end

  test "upload passes a multipart file and returns only adapter receipt" do
    adapter = Object.new
    adapter.define_singleton_method(:upload_media) do |_connection, file:|
      raise "not a multipart upload" unless file.is_a?(ActionDispatch::Http::UploadedFile)
      { id: "media1", path: "https://cdn.example/image.png", upload_token: "signed" }
    end
    Services::Definition.fetch("postiz").stub(:adapter, adapter) do
      Tempfile.create(["postiz", ".png"]) do |file|
        file.binmode
        file.write("\x89PNG\r\n\x1a\n".b)
        file.flush
        upload = Rack::Test::UploadedFile.new(file.path, "image/png")
        post @uploads, params: { file: upload }, headers: @headers
        assert_response :ok
        assert_equal "signed", response.parsed_body["upload_token"]
      end
    end
  end

  test "ambiguous write errors return once without retry" do
    adapter = Object.new
    count = 0
    adapter.define_singleton_method(:create_post) do |*args, **kwargs|
      count += 1
      raise Services::PostizAdapter::Error, "Outcome unknown. Check Postiz before retrying."
    end
    Services::Definition.fetch("postiz").stub(:adapter, adapter) do
      post @posts, params: { channel_id: "c1", content: "Hello", mode: "publish_now" }, headers: @headers, as: :json
      assert_response :bad_gateway
      assert_includes response.parsed_body["error"], "Outcome unknown"
    end
    assert_equal 1, count
  end

  test "unbounded publishing deletion and singular upload routes do not exist" do
    %w[publish schedule delete upload].each do |operation|
      assert_raises(ActionController::RoutingError) do
        Rails.application.routes.recognize_path(
          "/api/v1/service_connections/#{@connection.public_id}/postiz/#{operation}", method: :post
        )
      end
    end
  end
end

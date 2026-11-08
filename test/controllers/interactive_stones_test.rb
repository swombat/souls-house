require "test_helper"

class InteractiveStonesTest < ActionDispatch::IntegrationTest

  setup do
    @old_domain = ENV["SOULSHOUSE_STONES_DOMAIN"]
    ENV["SOULSHOUSE_STONES_DOMAIN"] = "soulstones.test"
    user = users(:confirmed_user)
    chat = user.personal_account.chats.create!(title: "Private source", model_id: "openrouter/auto")
    @stone = Stone.publish!(chat: chat, title: "Local music",
      html: '<!doctype html><html><head><title>Music</title></head><body><button>Play</button><script>document.body.dataset.ran="yes"</script></body></html>',
      author: user, public: true, interactive: true)
    @url = @stone.public_url
    @host = URI.parse(@url).host
  end

  teardown do
    ENV["SOULSHOUSE_STONES_DOMAIN"] = @old_domain
  end

  test "configured publication reserves its permanent hostname before presentation" do
    assert @stone.stone_address
    assert_equal @host, "#{@stone.stone_address.name}.soulstones.test"
  end

  test "legacy viewer redirects to isolated address but executable content never runs on house" do
    get "/stones/#{@stone.public_token}"
    assert_redirected_to @url
    get "/stones/#{@stone.public_token}/revisions/1/content"
    assert_response :not_found
    refute_includes response.headers["Content-Security-Policy"].to_s, "allow-scripts"
  end

  test "isolated viewer requires start and content has independent script-only sandbox" do
    host! @host
    get "/"
    assert_response :success
    assert_select "#stone-start", text: "Start interactive stone"
    assert_select "iframe", count: 0
    refute response.headers.key?("Set-Cookie")
    get "/revisions/1/content"
    assert_response :success
    assert_includes response.headers["Content-Security-Policy"], "sandbox allow-scripts;"
    refute_includes response.headers["Content-Security-Policy"], "allow-same-origin"
    assert_includes response.headers["Content-Security-Policy"], "connect-src 'none'"
    assert_includes response.headers["Permissions-Policy"], "microphone=()"
  end

  test "content domain does not expose house routes static files other stones or APIs" do
    host! @host
    [ "/login", "/api/v1/conversations", "/cable", "/favicon.ico",
      "/stones/#{@stone.public_token}", "/assets/example.js" ].each do |path|
      get path, headers: { "Cookie" => "session_id=synthetic", "Authorization" => "Bearer synthetic" }
      assert_response :not_found
      refute response.headers.key?("Set-Cookie")
    end
    post "/"
    assert_response :not_found
    get "/login", headers: { "X-Forwarded-Host" => "www.example.com" }
    assert_response :not_found
    host! "#{@host}."
    get "/login"
    assert_response :not_found
    host! "mystic-shadow-blur.soulstones.test"
    get "/revisions/1/content"
    assert_response :not_found
  end

  test "withdrawn and discarded stones are unavailable on their host" do
    host! @host
    @stone.chat.discard!
    get "/"
    assert_response :not_found
    @stone.chat.undiscard!
    @stone.withdraw!
    get "/revisions/1/content"
    assert_response :not_found
  end

  test "unsetting domain fails closed for interactive revisions and leaves static default" do
    ENV.delete("SOULSHOUSE_STONES_DOMAIN")
    get "/stones/#{@stone.public_token}"
    assert_response :not_found
    assert_raises(Stone::InvalidInput) do
      @stone.revise!(title: "Again", html: "<!doctype html><p>Hi</p>", author: users(:confirmed_user),
        public: true, interactive: true, base_revision_id: @stone.latest_revision.to_param)
    end
  end

  test "revision opt-in is immutable and static revisions keep their policy on isolated hosts" do
    first = @stone.latest_revision
    refute first.update(interactive: false)
    @stone.revise!(title: "Static edition", html: "<!doctype html><h1>Static</h1>",
      author: users(:confirmed_user), public: true, base_revision_id: first.to_param)
    host! @host
    get "/revisions/2/content"
    assert_response :success
    assert_equal StonesController::CONTENT_POLICY, response.headers["Content-Security-Policy"]
    get "/revisions/1/content"
    assert_response :success
    assert_includes response.headers["Content-Security-Policy"], "sandbox allow-scripts;"
  end

  test "API publication requires explicit interactive boolean and returns absolute public addresses" do
    key = ApiKey.generate_for(users(:confirmed_user), name: "Interactive tests", account: @stone.chat.account)
    headers = { "Authorization" => "Bearer #{key.raw_token}" }
    post "/api/v1/conversations/#{@stone.chat.to_param}/stones", params: {
      title: "API instrument", html: @stone.latest_revision.html_document, public: true, interactive: true
    }, headers: headers, as: :json
    assert_response :created
    payload = response.parsed_body.fetch("stone")
    assert_match %r{\Ahttps://[a-z]+-[a-z]+-[a-z]+\.soulstones\.test/\z}, payload.fetch("public_url")
    assert_equal true, payload.fetch("latest_revision").fetch("interactive")
    post "/api/v1/conversations/#{@stone.chat.to_param}/stones", params: {
      title: "Bad flag", html: "<!doctype html><p>Hi</p>", public: true, interactive: "false"
    }, headers: headers, as: :json
    assert_response :unprocessable_entity
  end

end

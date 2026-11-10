require "test_helper"

# Slice 2 of Field tables: an interactive stone revision reads attached
# tables. The trusted viewer fetches /revisions/N/data (bound to that exact
# revision) and hands rows to the frame; the frame keeps connect-src 'none'.
class StoneFieldTablesTest < ActionDispatch::IntegrationTest

  CHART = '<!doctype html><html><head><title>Chart</title></head><body><ul id="rows"></ul>' \
          "<script>for (const r of field.tables.Posts.rows) { const li = document.createElement('li'); " \
          "li.textContent = r.platform; document.getElementById('rows').append(li); }</script></body></html>".freeze

  setup do
    @old_domain = ENV["SOULSHOUSE_STONES_DOMAIN"]
    ENV["SOULSHOUSE_STONES_DOMAIN"] = "soulstones.test"
    @user = users(:confirmed_user)
    @account = @user.personal_account
    @chat = @account.chats.create!(title: "Charts", model_id: "openrouter/auto")
    @table = FieldTable.create_in!(@account, name: "Posts", by: @user, columns: [ { key: "platform" }, { key: "views", type: "number" } ])
    @table.add_rows!([ { "platform" => "x", "views" => 3 } ], by: @user)
    @other = FieldTable.create_in!(@account, name: "Private", by: @user, columns: [ { key: "secret" } ])
    @other.add_rows!([ { "secret" => "not for the stone" } ], by: @user)
    @stone = publish(field_table_ids: [ @table.to_param ])
    @host = URI.parse(@stone.public_url).host
  end

  teardown do
    ENV["SOULSHOUSE_STONES_DOMAIN"] = @old_domain
  end

  def publish(**options)
    Stone.publish!(chat: @chat, title: "Posts chart", html: CHART, author: @user, public: true, interactive: true,
      publish_tables: true, **options)
  end

  test "the data endpoint returns only this revision's attached tables" do
    host! @host
    get "/revisions/1/data"
    assert_response :success
    tables = JSON.parse(response.body)["tables"]
    assert_equal [ "Posts" ], tables.keys
    assert_equal [ { "platform" => "x", "views" => 3 } ], tables["Posts"]["rows"]
    assert_not_includes response.body, "not for the stone"
    refute response.headers.key?("Set-Cookie")
  end

  test "a revision without tables, another stone's revision, and an unknown number are 404" do
    revision = @stone.revise!(title: "No tables", html: CHART, author: @user, public: true,
      base_revision_id: @stone.latest_revision.to_param, interactive: true)
    host! @host
    get "/revisions/#{revision.number}/data"
    assert_response :not_found
    get "/revisions/9/data"
    assert_response :not_found

    bare = Stone.publish!(chat: @chat, title: "Bare", html: CHART, author: @user, public: true, interactive: true)
    host! URI.parse(bare.public_url).host
    get "/revisions/1/data"
    assert_response :not_found
  end

  test "a discarded table or a withdrawn stone stops serving at once" do
    host! @host
    @table.discard_by!(@user)
    get "/revisions/1/data"
    assert_response :not_found
    get "/revisions/1/content"
    assert_not_includes response.body, '"Posts"'

    @table.update_columns(discarded_at: nil)
    @stone.withdraw!
    get "/revisions/1/data"
    assert_response :not_found
  end

  test "detaching from the table stops the stone reading it" do
    @table.detach_stone!(@stone)
    host! @host
    get "/revisions/1/data"
    assert_response :not_found
    assert_empty @table.reading_stones
  end

  test "the content carries the shim and the first snapshot; the frame policy still forbids connections" do
    host! @host
    get "/revisions/1/content"
    assert_response :success
    assert_match(/<head><script>\(\(\) => \{/, response.body)
    assert_includes response.body, '"platform":"x"'
    assert_includes response.headers["Content-Security-Policy"], "connect-src 'none'"
    assert_includes response.headers["Content-Security-Policy"], "sandbox allow-scripts;"
    refute_includes response.headers["Content-Security-Policy"], "allow-same-origin"
  end

  test "the shim carries only a well-formed token from the frame URL, and the served revision" do
    host! @host
    get "/revisions/1/content", params: { k: "A" * 32 }
    assert_includes response.body, %(const token = "#{'A' * 32}";)
    assert_includes response.body, "const revision = 1;"
    get "/revisions/1/content", params: { k: "\"</script><script>alert(1)" }
    assert_includes response.body, "const token = null;"
    assert_not_includes response.body, "<script>alert(1)"
  end

  test "the snapshot cannot close its script tag" do
    @table.add_rows!([ { "platform" => "</script><script>alert(1)</script>" } ], by: @user)
    host! @host
    get "/revisions/1/content"
    assert_not_includes response.body, "<script>alert(1)"
    assert_includes response.body, "\\u003c/script\\u003e"
  end

  test "only the viewer of a revision that reads tables may connect, and only to itself" do
    host! @host
    get "/"
    assert_includes response.headers["Content-Security-Policy"], "connect-src 'self'"
    assert_select "#stone-container[data-tables=?]", "/revisions/1/data"
    assert_select "#stone-container > iframe", count: 0

    bare = Stone.publish!(chat: @chat, title: "Bare", html: CHART, author: @user, public: true, interactive: true)
    host! URI.parse(bare.public_url).host
    get "/"
    refute_includes response.headers["Content-Security-Policy"].to_s, "connect-src"
    assert_select "#stone-container[data-tables]", count: 0
  end

  test "attaching needs an interactive revision, the acknowledgement, and a live table of this account" do
    assert_raises(Stone::InvalidInput) { publish(field_table_ids: [ @table.to_param ], publish_tables: false) }
    error = assert_raises(Stone::InvalidInput) do
      Stone.publish!(chat: @chat, title: "Static", html: "<!doctype html><p>x</p>", author: @user, public: true,
        field_table_ids: [ @table.to_param ], publish_tables: true)
    end
    assert_match "interactive", error.message

    foreign = FieldTable.create_in!(accounts(:team_account), name: "Theirs")
    assert_raises(Stone::InvalidInput) { publish(field_table_ids: [ foreign.to_param ]) }
    @other.discard_by!(@user)
    assert_raises(Stone::InvalidInput) { publish(field_table_ids: [ @other.to_param ]) }
    assert_raises(Stone::InvalidInput) { publish(field_table_ids: [ "nonsense" ]) }
  end

  test "a guest resident cannot attach the visited account's tables" do
    guest = agents(:research_assistant)
    guest = agents(:code_reviewer) if guest.account_id == @account.id
    error = assert_raises(Stone::InvalidInput) do
      Stone.publish!(chat: @chat, title: "Guest chart", html: CHART, author: guest, public: true, interactive: true,
        field_table_ids: [ @table.to_param ], publish_tables: true)
    end
    assert_match "home Field", error.message
  end

  test "the API attaches tables with the acknowledgement and lists them on the revision" do
    key = ApiKey.generate_for(@user, name: "Stones", account: @account)
    headers = { "Authorization" => "Bearer #{key.raw_token}" }
    path = "/api/v1/conversations/#{@chat.to_param}/stones"
    post path, headers: headers, as: :json,
      params: { title: "Chart", html: CHART, public: true, interactive: true, field_table_ids: [ @table.to_param ] }
    assert_response :unprocessable_entity
    assert_match "publish_tables", JSON.parse(response.body)["error"]

    post path, headers: headers, as: :json,
      params: { title: "Chart", html: CHART, public: true, interactive: true, field_table_ids: [ @table.to_param ], publish_tables: true }
    assert_response :created
    assert_equal [ { "id" => @table.to_param, "name" => "Posts" } ], JSON.parse(response.body)["stone"]["latest_revision"]["field_tables"]
  end

  test "the boundary still refuses anything but GET on the stone paths" do
    host! @host
    post "/revisions/1/data"
    assert_response :not_found
    get "/revisions/1/data/more"
    assert_response :not_found
  end

end

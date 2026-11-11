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

  def publish(html: CHART, **options)
    Stone.publish!(chat: @chat, title: "Posts chart", html: html, author: @user, public: true, interactive: true,
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

  test "a page and rows with non-ASCII text are served with the shim" do
    @table.add_rows!([ { "platform" => "café…", "views" => 1 } ], by: @user)
    html = CHART.sub("<title>Chart</title>", "<title>Chart · ça va…</title>")
    stone = publish(field_table_ids: [ @table.to_param ], html: html)
    host! URI.parse(stone.public_url).host
    get "/revisions/1/content"
    assert_response :success
    body = response.body.force_encoding(Encoding::UTF_8)
    assert_includes body, "Chart · ça va…"
    assert_includes body, "café"
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

  # -- Writing through a write link (slice 3) --------------------------------

  def write(row, key: @stone.write_key, table: "Posts", number: 1)
    host! @host
    headers = { "Content-Type" => "application/json" }
    headers["X-Stone-Write-Key"] = key if key
    post "/revisions/#{number}/rows", params: { table: table, row: row }.to_json, headers: headers
  end

  test "a write link appends one row to a table the revision reads, written by the stone" do
    @stone.issue_write_key!
    assert_difference -> { @table.live_rows.count }, 1 do
      write({ "platform" => "bsky", "views" => "12" })
    end
    assert_response :created
    assert_equal({ "platform" => "bsky", "views" => 12 }, JSON.parse(response.body)["row"])
    row = @table.live_rows.last
    assert_equal @stone, row.last_written_by
    assert_equal "Stone: Posts chart", row.writer_name
    refute response.headers.key?("Set-Cookie")

    get "/revisions/1/data"
    assert_includes JSON.parse(response.body)["tables"]["Posts"]["rows"], { "platform" => "bsky", "views" => 12 }
  end

  test "no key, a wrong key, an old key or a revoked key writes nothing" do
    old = @stone.issue_write_key!
    @stone.issue_write_key!
    assert_no_difference -> { FieldTableRow.count } do
      write({ "platform" => "x" }, key: nil)
      assert_response :forbidden
      write({ "platform" => "x" }, key: "A" * 43)
      assert_response :forbidden
      write({ "platform" => "x" }, key: old)
      assert_response :forbidden
      key = @stone.write_key
      @stone.revoke_write_key!
      write({ "platform" => "x" }, key: key)
      assert_response :forbidden
    end
  end

  test "a write link reaches only the tables this revision reads, under the table's rules" do
    @stone.issue_write_key!
    assert_no_difference -> { FieldTableRow.count } do
      write({ "secret" => "x" }, table: "Private")
      assert_response :not_found
      write({ "nope" => "x" })
      assert_response :unprocessable_entity
      assert_match "not a column", JSON.parse(response.body)["error"]
      write({ "platform" => "x" * 5000 })
      assert_response :unprocessable_entity
      write("not an object")
      assert_response :unprocessable_entity
      write({ "platform" => "x" }, number: 9)
      assert_response :not_found
    end

    @table.detach_stone!(@stone)
    write({ "platform" => "x" })
    assert_response :not_found
  end

  test "a withdrawn stone or a non-interactive revision can't write" do
    @stone.issue_write_key!
    @stone.withdraw!
    write({ "platform" => "x" })
    assert_response :not_found
    assert_equal 1, @table.live_rows.count
  end

  test "the viewer offers writes only to a revision that reads tables, and never puts the key in the page" do
    @stone.issue_write_key!
    host! @host
    get "/"
    assert_select "#stone-container[data-writes=?]", "/revisions/1/rows"
    assert_select "#stone-writes[hidden]"
    assert_not_includes response.body, @stone.write_key
    get "/revisions/1/content"
    assert_not_includes response.body, @stone.write_key
    assert_includes response.body, "write,"
  end

  test "the API makes and revokes a write link for a stone that reads tables" do
    key = ApiKey.generate_for(@user, name: "Stones", account: @account)
    headers = { "Authorization" => "Bearer #{key.raw_token}" }
    path = "/api/v1/conversations/#{@chat.to_param}/stones/#{@stone.to_param}/write_link"
    post path, headers: headers, as: :json
    assert_response :created
    body = JSON.parse(response.body)["stone"]
    assert body["writable"]
    assert_equal @stone.reload.write_url, body["write_url"]

    delete path, headers: headers
    assert_response :no_content
    assert_not @stone.reload.writable?

    bare = Stone.publish!(chat: @chat, title: "Bare", html: CHART, author: @user, public: true, interactive: true)
    post "/api/v1/conversations/#{@chat.to_param}/stones/#{bare.to_param}/write_link", headers: headers, as: :json
    assert_response :unprocessable_entity
  end

  test "the boundary still refuses anything but GET on the stone paths" do
    host! @host
    post "/revisions/1/data"
    assert_response :not_found
    get "/revisions/1/data/more"
    assert_response :not_found
  end

end

require "test_helper"

# The Field page's search and its tag endpoints (FieldController#index with q
# and tag, FieldItemTagsController, FieldTagsController).
class FieldTagsWebTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    Setting.instance.update!(allow_agents: true)
    post login_path, params: { email_address: @user.email_address, password: "password123" }
    @note = @account.whiteboards.create!(name: "Week notes", content: "The Bach partita, slowly")
    @file = @account.field_files.create!(file: fixture_file_upload("test.txt", "text/plain"), title: "Receipts", uploaded_by: @user)
  end

  test "items carry their tags, and the page lists the account's tags" do
    @note.change_tags!(by: @user, add: %w[music life])
    get account_field_path(@account)
    props = page_props
    assert_equal %w[life music], props["items"].find { |n| n["key"] == "note-#{@note.to_param}" }["tags"]
    assert_equal [], props["items"].find { |i| i["kind"] == "file" }["tags"]
    assert_equal %w[life music], props["tags"].map { |t| t["name"] }
    assert_nil props["search"]
  end

  test "searching from the page returns excerpts and keeps the tag filter" do
    @note.change_tags!(by: @user, add: [ "music" ])
    get account_field_path(@account, q: "partita", tag: [ "music" ])
    props = page_props
    result = props.dig("search", "results").sole
    assert_equal "note-#{@note.to_param}", result["key"]
    assert_equal [ "music" ], props["filter_tags"]
    assert_equal "partita", result["excerpts"].first["text"][*result["excerpts"].first["matches"].first]

    get account_field_path(@account, q: "partita", tag: [ "life" ])
    assert_empty page_props.dig("search", "results")

    get account_field_path(@account, q: "!!!")
    assert page_props.dig("search", "error").present?
  end

  test "a later page of results is what the page asks for" do
    25.times { |i| @account.whiteboards.create!(name: "Repeat #{i}", content: "repeated") }
    get account_field_path(@account, q: "repeated", page: "1", item: "note-#{@note.to_param}")
    assert_equal 1, page_props.dig("search", "page")
    assert_equal 5, page_props.dig("search", "results").size
  end

  test "a person tags an item by its page key" do
    patch account_field_item_tags_path(@account), params: { item: "file-#{@file.to_param}", add: [ "GrantTree" ] }, as: :json
    assert_response :success
    assert_equal [ "granttree" ], response.parsed_body["tags"]
    assert_equal @user, FieldTagging.kept.sole.tagged_by

    patch account_field_item_tags_path(@account), params: { item: "file-#{@file.to_param}", remove: [ "granttree" ] }, as: :json
    assert_empty @file.tag_names
  end

  test "another account's item can't be tagged from this page" do
    other = accounts(:another_team).field_files.create!(file: fixture_file_upload("test.txt", "text/plain"))
    patch account_field_item_tags_path(@account), params: { item: "file-#{other.to_param}", add: [ "x" ] }, as: :json
    assert_response :not_found
    patch account_field_item_tags_path(@account), params: { item: "chat-abc", add: [ "x" ] }, as: :json
    assert_response :not_found
  end

  test "a member renames, merges and deletes tags" do
    @note.change_tags!(by: @user, add: %w[Life personal])
    personal = @account.field_tags.find_by!(name: "personal")

    patch account_field_tag_path(@account, personal), params: { name: "life" }, as: :json
    assert_response :conflict
    patch account_field_tag_path(@account, personal), params: { name: "life", merge: true }, as: :json
    assert_response :success
    assert_equal [ "life" ], @note.tag_names

    delete account_field_tag_path(@account, @account.field_tags.kept.sole)
    assert_response :no_content
    assert_empty @note.tag_names
  end

  test "another account's tag can't be touched" do
    other_note = accounts(:another_team).whiteboards.create!(name: "Theirs", content: "x")
    other_note.change_tags!(by: @user, add: [ "theirs" ])
    tag = accounts(:another_team).field_tags.sole
    delete account_field_tag_path(@account, tag)
    assert_response :not_found
    assert tag.reload.kept?
  end

  private

  def page_props
    JSON.parse(Nokogiri::HTML(response.body).at_css("[data-page]")&.[]("data-page") || response.body)["props"]
  end

end

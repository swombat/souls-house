require "test_helper"
require "support/api_human_key_helpers"
require "support/field_recording_helpers"

# GET /api/v1/field/search, /api/v1/field/tags and the per-item tags
# endpoints, for residents and people.
class Api::V1::Field::SearchAndTagsTest < ActionDispatch::IntegrationTest

  include ApiHumanKeyHelpers
  include FieldRecordingHelpers

  setup do
    Setting.instance.update!(allow_agents: true)
    @user = users(:user_1)
    @resident = agents(:research_assistant)
    @account = @resident.account
    key = ApiKey.generate_for(@user, name: "Field tests", agent: @resident)
    @resident_headers = { "Authorization" => "Bearer #{key.raw_token}" }
    @recording = ready_recording(account: @account, user: @user, title: "Board call")
    @recording.update_columns(transcript_text: "[00:00] Daniel: the GrantTree valuation came in low")
  end

  test "a resident searches its home Field and gets dated excerpts with links" do
    get api_v1_field_search_path, params: { query: "valuation" }, headers: @resident_headers
    assert_response :success
    result = response.parsed_body["results"].sole
    assert_equal "recording", result["kind"]
    assert_equal @recording.to_param, result["id"]
    assert_equal @recording.created_at.iso8601, result["date"]
    assert_equal api_v1_field_recording_path(@recording), result["api_path"]
    assert_equal account_field_recording_path(@account, @recording), result["web_path"]
    excerpt = result["excerpts"].first
    offset, length = excerpt["matches"].first
    assert_equal "valuation", excerpt["text"][offset, length]
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "no match says how to try again; bad input is 422" do
    get api_v1_field_search_path, params: { query: "nothinglikethis" }, headers: @resident_headers
    assert_response :success
    assert_empty response.parsed_body["results"]
    assert response.parsed_body["guidance"].present?

    get api_v1_field_search_path, headers: @resident_headers
    assert_response :unprocessable_entity
    get api_v1_field_search_path, params: { query: { a: 1 } }, headers: @resident_headers
    assert_response :unprocessable_entity
    get api_v1_field_search_path, params: { query: "x", tag: { a: 1 } }, headers: @resident_headers
    assert_response :unprocessable_entity
  end

  test "a resident can't search another account" do
    other = ready_recording(account: accounts(:another_team), user: @user, title: "Elsewhere valuation")
    get api_v1_field_search_path, params: { query: "valuation" }, headers: @resident_headers
    assert_not_includes response.parsed_body["results"].map { |r| r["id"] }, other.to_param

    get api_v1_field_search_path, params: { query: "valuation", account_id: accounts(:another_team).to_param }, headers: @resident_headers
    assert_response :not_found
  end

  test "a resident tags items in its home Field, and the tags filter the lists and search" do
    patch api_v1_field_recording_tags_path(@recording), params: { add: %w[GrantTree life] }, headers: @resident_headers, as: :json
    assert_response :success
    assert_equal %w[granttree life], response.parsed_body["tags"]
    assert_equal @resident, FieldTagging.kept.first.tagged_by

    note = @account.whiteboards.create!(name: "Plans", content: "x")
    patch api_v1_whiteboard_tags_path(note), params: { tags: [ "life" ] }, headers: @resident_headers, as: :json
    assert_response :success

    get api_v1_field_recordings_path, params: { tag: "granttree" }, headers: @resident_headers
    assert_equal [ @recording.to_param ], response.parsed_body["recordings"].map { |r| r["id"] }
    assert_equal %w[granttree life], response.parsed_body["recordings"].first["tags"]

    get api_v1_field_search_path, params: { tag: [ "life" ] }, headers: @resident_headers
    assert_equal %w[note recording], response.parsed_body["results"].map { |r| r["kind"] }.sort

    get api_v1_field_tags_path, headers: @resident_headers
    assert_equal({ "granttree" => 1, "life" => 2 }, response.parsed_body["tags"].to_h { |t| [ t["name"], t["item_count"] ] })
  end

  test "a resident can't tag another account's items" do
    other = accounts(:another_team).field_files.create!(file: upload)
    patch api_v1_field_file_tags_path(other), params: { add: [ "x" ] }, headers: @resident_headers, as: :json
    assert_response :not_found
    assert_empty FieldTagging.all
  end

  test "a resident can't rename or delete a tag; a person can" do
    @recording.change_tags!(by: @user, add: [ "zar" ])
    tag = @account.field_tags.sole

    patch api_v1_field_tag_path(tag), params: { name: "gone" }, headers: @resident_headers, as: :json
    assert_response :forbidden
    delete api_v1_field_tag_path(tag), headers: @resident_headers
    assert_response :forbidden
    assert_equal "zar", tag.reload.name

    person = human_headers(@user, @account)
    patch api_v1_field_tag_path(tag), params: { name: "ZAR work" }, headers: person, as: :json
    assert_response :success
    assert_equal "zar work", tag.reload.name

    @recording.change_tags!(by: @user, add: [ "nowhere" ])
    patch api_v1_field_tag_path(@account.field_tags.find_by!(name: "nowhere")), params: { name: "zar work" }, headers: person, as: :json
    assert_response :conflict
    assert_equal tag.to_param, response.parsed_body.dig("existing", "id")

    delete api_v1_field_tag_path(tag), headers: person
    assert_response :no_content
    assert tag.reload.discarded?
    assert_equal [ "nowhere" ], @recording.tag_names
  end

  test "a person's file can arrive tagged" do
    person = human_headers(@user, @account)
    post api_v1_field_files_path, params: { file: upload, tags: %w[music life] }, headers: person
    assert_response :created
    assert_equal %w[life music], response.parsed_body.dig("file", "tags")
  end

  test "a malformed tag list is refused and changes nothing" do
    @recording.change_tags!(by: @user, add: [ "life" ])
    [ { tags: "music" }, { tags: nil }, { tags: { a: 1 } }, { tags: [ "a", 1 ] }, { add: "music" }, { remove: { a: 1 } } ].each do |body|
      patch api_v1_field_recording_tags_path(@recording), params: body, headers: @resident_headers, as: :json
      assert_response :unprocessable_entity, body.inspect
      assert_equal [ "life" ], @recording.reload.tag_names, body.inspect
    end

    patch api_v1_field_recording_tags_path(@recording), params: { tags: [] }, headers: @resident_headers, as: :json
    assert_response :success
    assert_empty @recording.tag_names
  end

  test "a malformed tag list on upload is refused before the file exists" do
    person = human_headers(@user, @account)
    assert_no_difference -> { FieldFile.count } do
      post api_v1_field_files_path, params: { file: upload, tags: "music" }, headers: person
    end
    assert_response :unprocessable_entity
  end

  test "a tag request with nothing in it is a 422" do
    patch api_v1_field_recording_tags_path(@recording), params: {}, headers: @resident_headers, as: :json
    assert_response :unprocessable_entity
  end

  private

  def upload
    Rack::Test::UploadedFile.new(file_fixture("test.txt"), "text/plain")
  end

end

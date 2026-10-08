require "test_helper"
require "support/api_human_key_helpers"

# PATCH /api/v1/field/files/:id with a person's key (FieldFilesController#update).
class Api::V1::Field::HumanFilesTest < ActionDispatch::IntegrationTest

  include ApiHumanKeyHelpers

  setup do
    Setting.instance.update!(allow_agents: true)
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @headers = human_headers(@user, @account)
    @file = @account.field_files.create!(file: upload, title: "Tuesday", uploaded_by: @user)
  end

  test "a person edits a file's title and note" do
    patch api_v1_field_file_path(@file), params: { title: "Wednesday", note: "From the call" }, headers: @headers, as: :json
    assert_response :success
    assert_equal "Wednesday", response.parsed_body.dig("file", "title")
    assert_equal [ "Wednesday", "From the call" ], [ @file.reload.title, @file.note ]
  end

  test "an invalid title is refused" do
    patch api_v1_field_file_path(@file), params: { title: "x" * 201 }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_equal "Tuesday", @file.reload.title

    patch api_v1_field_file_path(@file), params: {}, headers: @headers, as: :json
    assert_response :unprocessable_entity
  end

  test "a resident key can't edit, another account's file is 404, and a former member reaches nothing" do
    patch api_v1_field_file_path(@file), params: { title: "Nope" }, headers: resident_headers(@user, agents(:research_assistant)), as: :json
    assert_response :forbidden

    theirs = accounts(:another_team).field_files.create!(file: upload, title: "Theirs", uploaded_by: users(:user_1))
    patch api_v1_field_file_path(theirs), params: { title: "Nope" }, headers: @headers, as: :json
    assert_response :not_found

    end_membership!(@user, @account)
    patch api_v1_field_file_path(@file), params: { title: "Nope" }, headers: @headers, as: :json
    assert_response :not_found
    assert_equal "Tuesday", @file.reload.title
  end

  test "the Field feature being off closes editing" do
    Setting.instance.update!(allow_agents: false)
    patch api_v1_field_file_path(@file), params: { title: "Nope" }, headers: @headers, as: :json
    assert_response :forbidden
  end

  private

  def upload
    Rack::Test::UploadedFile.new(file_fixture("test.txt"), "text/plain")
  end

end

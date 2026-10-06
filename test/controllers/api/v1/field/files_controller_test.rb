require "test_helper"

class Api::V1::Field::FilesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @resident = agents(:research_assistant)
    @account = @resident.account
    @headers = headers_for(@resident)
    @human_file = @account.field_files.create!(file: upload, title: "Tuesday", uploaded_by: @user)
  end

  test "requires a token" do
    get api_v1_field_files_path
    assert_response :unauthorized
  end

  test "a resident lists and reads the Field of its account" do
    get api_v1_field_files_path, headers: @headers
    assert_response :success
    listed = response.parsed_body["files"]
    assert_equal [ @human_file.to_param ], listed.map { |f| f["id"] }
    assert_equal({ "kind" => "human", "name" => @human_file.uploader_name }, listed.first["uploaded_by"])

    get api_v1_field_file_path(@human_file), headers: @headers
    assert_response :success
    assert_equal download_api_v1_field_file_path(@human_file), response.parsed_body.dig("file", "download_path")
  end

  test "download redirects to a short-lived attachment URL" do
    get download_api_v1_field_file_path(@human_file), headers: @headers
    assert_response :redirect
    token = URI(response.location).path.split("/")[-2].split("--").first
    assert_match(/attachment; filename=/, Base64.decode64(token))
  end

  test "a resident cannot reach another account's Field" do
    other = accounts(:another_team).field_files.create!(file: upload)
    get api_v1_field_file_path(other), headers: @headers
    assert_response :not_found
    get download_api_v1_field_file_path(other), headers: @headers
    assert_response :not_found
    delete api_v1_field_file_path(other), headers: @headers
    assert_response :not_found
    assert FieldFile.exists?(other.id)

    get api_v1_field_files_path, headers: @headers
    assert_not_includes response.parsed_body["files"].map { |f| f["id"] }, other.to_param
  end

  test "a resident brings a file in, attributed to itself" do
    assert_difference -> { @account.field_files.count }, 1 do
      post api_v1_field_files_path, params: { file: upload, note: "For Sunday" }, headers: @headers
    end
    assert_response :created
    created = @account.field_files.find(response.parsed_body.dig("file", "id"))
    assert_equal @resident, created.uploaded_by
    assert_equal "test.txt", created.title
  end

  test "a signed blob ID is refused, so no blob can be reattached into the Field" do
    chat = @account.chats.create!(model_id: "openrouter/auto", title: "Old")
    message = chat.messages.create!(content: "Old file", role: "user", user: @user)
    message.attachments.attach(io: file_fixture("test.txt").open, filename: "old.txt", content_type: "text/plain")
    blob = message.attachments.first.blob
    message.discard!

    assert_no_difference -> { FieldFile.count } do
      post api_v1_field_files_path, params: { file: blob.signed_id }, headers: @headers
    end
    assert_response :unprocessable_entity
    assert_equal 1, ActiveStorage::Attachment.where(blob_id: blob.id).count
  end

  test "an upload without a file is a 422" do
    post api_v1_field_files_path, params: { title: "Nothing" }, headers: @headers
    assert_response :unprocessable_entity
  end

  test "a resident deletes only what it brought" do
    delete api_v1_field_file_path(@human_file), headers: @headers
    assert_response :forbidden
    assert FieldFile.exists?(@human_file.id)

    sibling_file = @account.field_files.create!(file: upload, uploaded_by: agents(:code_reviewer))
    delete api_v1_field_file_path(sibling_file), headers: @headers
    assert_response :forbidden

    own = @account.field_files.create!(file: upload, uploaded_by: @resident)
    delete api_v1_field_file_path(own), headers: @headers
    assert_response :no_content
    assert own.reload.discarded?
    assert own.file.attached?
  end

  test "a discarded file disappears from list, metadata and download" do
    @human_file.discard!
    get api_v1_field_files_path, headers: @headers
    assert_empty response.parsed_body["files"]
    get api_v1_field_file_path(@human_file), headers: @headers
    assert_response :not_found
    get download_api_v1_field_file_path(@human_file), headers: @headers
    assert_response :not_found
    delete api_v1_field_file_path(@human_file), headers: @headers
    assert_response :not_found
  end

  test "a human API key can delete any file in its account" do
    key = ApiKey.generate_for(@user, name: "Human", account: @account)
    delete api_v1_field_file_path(@human_file), headers: { "Authorization" => "Bearer #{key.raw_token}" }
    assert_response :no_content
    assert @human_file.reload.discarded?
  end

  private

  def upload
    Rack::Test::UploadedFile.new(file_fixture("test.txt"), "text/plain")
  end

  def headers_for(agent)
    key = ApiKey.generate_for(@user, name: "Field tests", agent: agent)
    { "Authorization" => "Bearer #{key.raw_token}" }
  end

end

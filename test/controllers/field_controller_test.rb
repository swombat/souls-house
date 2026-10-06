require "test_helper"

class FieldControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    Setting.instance.update!(allow_agents: true)
    post login_path, params: { email_address: @user.email_address, password: "password123" }
  end

  def upload(name = "test.txt", type = "text/plain")
    fixture_file_upload(name, type)
  end

  test "the Field page renders with files and notes" do
    @account.field_files.create!(file: upload, title: "Tuesday meeting", uploaded_by: @user)
    @account.whiteboards.create!(name: "Week notes", content: "# Week")

    get account_field_path(@account)
    assert_response :success
    props = inertia_props
    assert_equal [ "Tuesday meeting" ], props["files"].map { |f| f["title"] }
    assert_includes props["notes"].map { |n| n["title"] }, "Week notes"
    assert_equal @account.name, props["account_name"]
    assert_equal 1.gigabyte, props["max_file_bytes"]
    assert_equal "1 GB", props["max_file_label"]
  end

  test "a human brings a file into the Field" do
    assert_difference -> { @account.field_files.count }, 1 do
      post account_field_files_path(@account),
        params: { field_file: { file: upload, title: "Notes from Tuesday", note: "I came away uneasy." } }
    end
    file = @account.field_files.last
    assert_equal @user, file.uploaded_by
    assert_equal "I came away uneasy.", file.note
    assert file.file.attached?
    assert_redirected_to account_field_path(@account, tab: "files", item: "file-#{file.to_param}")
  end

  test "an upload without a file is refused" do
    assert_no_difference -> { FieldFile.count } do
      post account_field_files_path(@account), params: { field_file: { title: "Empty" } }
    end
    assert_redirected_to account_field_path(@account, tab: "files")
  end

  test "a signed blob ID is not accepted as an upload, even for a discarded message's file" do
    chat = @account.chats.create!(model_id: "openrouter/auto", title: "Old")
    message = chat.messages.create!(content: "Old file", role: "user", user: @user)
    message.attachments.attach(io: file_fixture("test.txt").open, filename: "old.txt", content_type: "text/plain")
    signed_id = message.attachments.first.blob.signed_id
    message.discard!

    assert_no_difference -> { FieldFile.count } do
      post account_field_files_path(@account), params: { field_file: { file: signed_id, title: "Reattached" } }
    end
    assert_equal 1, ActiveStorage::Attachment.where(blob_id: message.attachments.first.blob_id).count
  end

  test "deleting a file discards it: hidden everywhere, row and bytes kept" do
    file = @account.field_files.create!(file: upload, uploaded_by: @user)
    old_url = FieldItems.file_json(file)[:download_url]

    assert_no_enqueued_jobs(only: ActiveStorage::PurgeJob) do
      delete account_field_file_path(@account, file)
    end
    assert file.reload.discarded?
    assert ActiveStorage::Blob.exists?(file.file.blob.id)

    get account_field_path(@account)
    assert_not_includes inertia_props["files"].map { |f| f["id"] }, file.to_param

    get old_url
    follow_redirect! if response.redirect?
    assert_response :not_found

    file.undiscard!
    get old_url
    assert_response :redirect
  end

  test "one reachability rule across discarded messages and discarded Field files" do
    file = @account.field_files.create!(file: upload, uploaded_by: @user)
    blob = file.file.blob
    chat = @account.chats.create!(model_id: "openrouter/auto", title: "Shared blob")
    message = chat.messages.create!(content: "Same bytes", role: "user", user: @user)
    message.attachments.attach(blob)
    url = Rails.application.routes.url_helpers.rails_blob_path(blob, disposition: :attachment, only_path: true)

    file.discard!
    get url
    assert_response :redirect, "a kept message still owns the blob"

    message.discard!
    get url
    follow_redirect! if response.redirect?
    assert_response :not_found, "discarded owners must not keep each other reachable"

    file.undiscard!
    get url
    assert_response :redirect, "a kept Field file still owns the blob"
  end

  test "another account's files cannot be deleted or edited" do
    other = accounts(:another_team)
    file = other.field_files.create!(file: upload)

    delete account_field_file_path(@account, file)
    assert_response :not_found
    patch account_field_file_path(@account, file), params: { field_file: { title: "Mine now" } }
    assert_response :not_found
    assert FieldFile.exists?(file.id)
  end

  test "the Field page shows only this account's files" do
    accounts(:another_team).field_files.create!(file: upload, title: "Not ours")
    get account_field_path(@account)
    assert_not_includes inertia_props["files"].map { |f| f["title"] }, "Not ours"
  end

  private

  def inertia_props
    JSON.parse(Nokogiri::HTML(response.body).at_css("[data-page]")&.[]("data-page") || response.body)["props"]
  end

end

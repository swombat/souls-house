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
    assert_equal 100, props["max_file_megabytes"]
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

  test "an upload without a file is refused with a message" do
    assert_no_difference -> { FieldFile.count } do
      post account_field_files_path(@account), params: { field_file: { title: "Empty" } }
    end
    assert_redirected_to account_field_path(@account, tab: "files")
    assert_match(/must be attached/, flash[:alert])
  end

  test "deleting a file removes the row and queues the stored file for purge" do
    file = @account.field_files.create!(file: upload, uploaded_by: @user)
    assert_enqueued_with(job: ActiveStorage::PurgeJob) do
      delete account_field_file_path(@account, file)
    end
    assert_not FieldFile.exists?(file.id)
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

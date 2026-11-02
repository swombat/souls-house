require "test_helper"

# Export and import endpoints: owners only, scoped to the account, private.
class Accounts::PortabilityControllerTest < ActionDispatch::IntegrationTest

  include ActiveJob::TestHelper

  setup do
    @user = users(:user_1)
    @account = Account.create!(name: "Portable #{SecureRandom.hex(3)}", account_type: "team")
    @account.memberships.create!(user: @user, role: "owner", confirmed_at: Time.current)
    @other = Account.create!(name: "Someone else #{SecureRandom.hex(3)}", account_type: "team")
    post login_path, params: { email_address: @user.email_address, password: "password123" }
  end

  def ready_export(account)
    export = account.account_exports.create!(user: @user, status: "ready", expires_at: 1.day.from_now, summary: { "export_id" => SecureRandom.uuid })
    export.archive.attach(io: StringIO.new("PK synthetic"), filename: "a.zip", content_type: "application/zip")
    export
  end

  test "the page shows limits, what never travels, and which residents would be skipped" do
    get account_portability_path(@account)
    assert_response :success
    assert_equal "accounts/portability", inertia_component
    assert_equal "private, no-store", response.headers["Cache-Control"]
    props = inertia_shared_props
    assert_equal Accounts::Portability::Archive::MAX_ENTRY, props["limits"]["entry"]
    assert_includes props["never_travels"].join(" "), "credentials"
    assert_nil props["destination_refusal"]
  end

  test "export starts one job at a time and the download is private and audited" do
    assert_enqueued_with(job: AccountPortability::ExportJob) do
      post account_exports_path(@account), params: { include_conversations: "true" }
    end
    assert @account.account_exports.sole.include_conversations
    assert_no_enqueued_jobs(only: AccountPortability::ExportJob) { post account_exports_path(@account) }

    export = ready_export(@account)
    get download_account_export_path(@account, export)
    assert_response :success
    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_equal "PK synthetic", response.body
    assert AuditLog.exists?(action: "download_account_archive", auditable: export)

    export.update!(expires_at: 1.minute.ago)
    get download_account_export_path(@account, export)
    assert_response :not_found
  end

  test "another account's export and import are out of reach" do
    @other.memberships.create!(user: users(:existing_user), role: "owner", confirmed_at: Time.current)
    theirs = ready_export(@other)
    get download_account_export_path(@account, theirs)
    assert_response :not_found
    import = @other.account_imports.create!(user: users(:existing_user), status: "previewed", archive_sha256: "a" * 64)
    post confirm_account_import_path(@account, import), params: { sha256: "a" * 64, confirmed: "true" }
    assert_response :not_found
    get download_account_export_path(@other, theirs)
    assert_response :not_found
    refute_equal "importing", import.reload.status
  end

  test "a member who is not an owner cannot export, download or import" do
    @account.memberships.find_by!(user: @user).update_column(:role, "member")
    export = ready_export(@account)
    get account_portability_path(@account)
    assert_response :redirect
    get download_account_export_path(@account, export)
    assert_response :redirect
    assert_no_difference(-> { AccountExport.count }) { post account_exports_path(@account) }
    assert_no_difference(-> { AccountImport.count }) { post account_imports_path(@account), params: { archive: fixture_file_upload("test.txt", "text/plain") } }
  end

  test "upload is refused into an account that is not empty, and confirm must carry the previewed hash" do
    assert_enqueued_with(job: AccountPortability::ValidateJob) do
      post account_imports_path(@account), params: { archive: fixture_file_upload("test.txt", "application/zip") }
    end
    import = @account.account_imports.sole
    import.update!(status: "previewed", archive_sha256: "b" * 64, preview: { "sha256" => "b" * 64 })

    assert_no_enqueued_jobs(only: AccountPortability::ImportJob) do
      post confirm_account_import_path(@account, import), params: { sha256: "c" * 64, confirmed: "true" }
      post confirm_account_import_path(@account, import), params: { sha256: "b" * 64, confirmed: "false" }
    end
    assert_equal "previewed", import.reload.status
    assert_enqueued_with(job: AccountPortability::ImportJob) do
      post confirm_account_import_path(@account, import), params: { sha256: "b" * 64, confirmed: "true" }
    end
    assert_equal "importing", import.reload.status

    @account.whiteboards.create!(name: "Here already", content: "x")
    assert_no_difference(-> { AccountImport.count }) do
      post account_imports_path(@account), params: { archive: fixture_file_upload("test.txt", "application/zip") }
    end
    assert_match(/already has things in its Field/, flash[:alert])
  end

end

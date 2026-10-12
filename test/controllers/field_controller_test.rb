require "test_helper"
require "support/field_recording_helpers"

class FieldControllerTest < ActionDispatch::IntegrationTest

  include FieldRecordingHelpers

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
    assert_equal [ "Tuesday meeting" ], props["items"].select { |i| i["kind"] == "file" }.map { |f| f["title"] }
    assert_includes props["items"].select { |i| i["kind"] == "note" }.map { |n| n["title"] }, "Week notes"
    assert_equal @account.name, props["account_name"]
    assert_equal 100.megabytes, props["max_file_bytes"]
    assert_equal "100 MB", props["max_file_label"]
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

  test "a human dates a file as it comes in; an impossible date makes nothing" do
    post account_field_files_path(@account), params: { field_file: { file: upload, dated_at: "2019-03-14" } }
    assert_equal Time.zone.local(2019, 3, 14), @account.field_files.last.dated_at

    assert_no_difference -> { FieldFile.count } do
      post account_field_files_path(@account), params: { field_file: { file: upload, dated_at: "2019-02-30" } }
    end
    assert_redirected_to account_field_path(@account, tab: "files")
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
    assert_not_includes inertia_props["items"].map { |f| f["id"] }, file.to_param

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
    assert_not_includes inertia_props["items"].select { |i| i["kind"] == "file" }.map { |f| f["title"] }, "Not ours"
  end

  test "the list comes a page at a time, newest first, with counts per tab" do
    @account.whiteboards.update_all(deleted_at: Time.current) # fixtures' notes
    files = 53.times.map { |i| @account.field_files.create!(file: upload, title: "File #{i}", uploaded_by: @user, created_at: i.minutes.ago) }
    @account.whiteboards.create!(name: "Old note", content: "# Old").update_columns(updated_at: 2.days.ago, last_edited_at: 2.days.ago)

    get account_field_path(@account)
    props = inertia_props
    assert_equal 50, props["items"].size
    assert_equal "File 0", props["items"].first["title"]
    assert_equal({ "page" => 1, "pages" => 2, "per_page" => 50, "total" => 54 }, props["pagination"])
    assert_equal({ "all" => 54, "files" => 53, "notes" => 1, "recordings" => 0, "tweets" => 0, "waiting" => 0 }, props["counts"])
    assert_nil props["items"].find { |i| i["kind"] == "note" }

    get account_field_path(@account, page: "2")
    props = inertia_props
    assert_equal [ "File 50", "File 51", "File 52", "Old note" ], props["items"].map { |i| i["title"] }
    assert_nil props["items"].last["content"], "listed notes leave their content behind"

    get account_field_path(@account, page: "9", tab: "notes")
    props = inertia_props
    assert_equal 1, props["pagination"]["page"], "a page past the end shows the last page"
    assert_equal [ "Old note" ], props["items"].map { |i| i["title"] }

    get account_field_path(@account, item: "file-#{files.last.to_param}")
    props = inertia_props
    assert_equal "File 52", props["current_item"]["title"], "the open item is sent even when it's on another page"
    assert_equal "file-#{files.last.to_param}", props["selected"]
  end

  test "an imported recording sorts and shows by when it was recorded, not when it arrived" do
    @account.whiteboards.update_all(deleted_at: Time.current)
    @account.field_files.create!(file: upload, title: "Yesterday's file", uploaded_by: @user, created_at: 1.day.ago)
    imported = ready_recording(account: @account, user: @user, title: "January call", recorded_at: Time.zone.parse("2026-01-15 07:54"))

    get account_field_path(@account)
    items = inertia_props["items"]
    assert_equal [ "Yesterday's file", "January call" ], items.map { |i| i["title"] }
    assert_equal imported.recorded_at.iso8601, items.last["recorded_at"]
    assert_equal [ imported ], @account.field_recordings.newest_first.to_a
  end

  test "an imported file or note sorts and shows by the date it is from" do
    @account.whiteboards.update_all(deleted_at: Time.current)
    @account.field_files.create!(file: upload, title: "Yesterday's file", uploaded_by: @user, created_at: 1.day.ago)
    old_file = @account.field_files.create!(file: upload, title: "2019 transcript", uploaded_by: @user, dated_at: Time.zone.parse("2019-03-14"))
    old_note = @account.whiteboards.create!(name: "2018 diary", content: "It rained.", dated_at: Time.zone.parse("2018-05-01"))

    get account_field_path(@account)
    items = inertia_props["items"]
    assert_equal [ "Yesterday's file", "2019 transcript", "2018 diary" ], items.map { |i| i["title"] }
    assert_equal [ old_file.dated_at.iso8601, old_note.dated_at.iso8601 ], items.last(2).map { |i| i["dated_at"] }
  end

  test "the tag filter narrows the list and its counts on the server" do
    tagged = @account.field_files.create!(file: upload, title: "Tagged", uploaded_by: @user)
    @account.field_files.create!(file: upload, title: "Plain", uploaded_by: @user)
    tagged.change_tags!(by: @user, add: %w[life])

    get account_field_path(@account, tag: "life")
    props = inertia_props
    assert_equal [ "Tagged" ], props["items"].map { |i| i["title"] }
    assert_equal 1, props["counts"]["all"]
    assert_not props["field_empty"]
  end

  test "the waiting tab lists recordings with a speaker still to name, and drops them once named" do
    @account.whiteboards.update_all(deleted_at: Time.current)
    @account.field_files.create!(file: upload, title: "A file", uploaded_by: @user)
    named = ready_recording(account: @account, user: @user, title: "All named")
    waiting = ready_recording(account: @account, user: @user, title: "Two to name")
    queued_recording(account: @account, user: @user, title: "Still transcribing")
    voice = @account.field_voices.create!(name: "Ana")
    named.speakers.each { |speaker| speaker.name_as!(voice, by: @user) }

    get account_field_path(@account, tab: "waiting")
    props = inertia_props
    assert_equal "waiting", props["tab"]
    assert_equal [ "Two to name" ], props["items"].map { |i| i["title"] }
    assert_equal 1, props["counts"]["waiting"]
    assert_equal 3, props["counts"]["recordings"], "the other tabs count as before"

    waiting.speakers.first.name_as!(voice, by: @user)
    get account_field_path(@account, tab: "waiting")
    assert_equal [ "Two to name" ], inertia_props["items"].map { |i| i["title"] }, "one speaker left still waits"

    waiting.speakers.last.name_as!(voice, by: @user)
    get account_field_path(@account, tab: "waiting")
    assert_empty inertia_props["items"]
    assert_equal 0, inertia_props["counts"]["waiting"]

    voice.update_columns(discarded_at: Time.current)
    get account_field_path(@account, tab: "waiting")
    assert_equal [ "All named", "Two to name" ].sort, inertia_props["items"].map { |i| i["title"] }.sort,
      "a deleted voice leaves its speakers waiting again"
  end

  test "an open note carries its content" do
    note = @account.whiteboards.create!(name: "Week notes", content: "# Week")
    get account_field_path(@account, item: "note-#{note.to_param}")
    assert_equal "# Week", inertia_props["current_item"]["content"]
  end

  test "an unknown or foreign item opens nothing" do
    other = accounts(:another_team).field_files.create!(file: upload, title: "Not ours")
    get account_field_path(@account, item: "file-#{other.to_param}")
    assert_nil inertia_props["current_item"]
    get account_field_path(@account, item: "nonsense")
    assert_nil inertia_props["current_item"]
  end

  test "an open PDF carries its pages' text; the list carries only the reading state" do
    pdf = @account.field_files.create!(uploaded_by: @user,
      file: Rack::Test::UploadedFile.new(Rails.root.join("test/fixtures/files/field_pdfs/mixed.pdf"), "application/pdf"))
    pdf.extract_pdf!

    get account_field_path(@account, item: "file-#{pdf.to_param}")
    props = inertia_props
    listed = props["items"].find { it["id"] == pdf.to_param }
    assert_equal "extracted", listed.dig("text_extraction", "status")
    assert_nil listed["pages"]

    pages = props["current_item"]["pages"]
    assert_equal %w[text text empty empty], pages.map { it["status"] }
    assert_equal "Orchard ledger, page one: apricots and quinces.", pages.first["text"]
    assert_nil pages.third["text"]
  end

  test "a file's summary can be written again, and the list says one is coming" do
    file = @account.field_files.create!(file: upload, title: "Orchard", uploaded_by: @user)
    file.update_columns(extracted_text: "We replant the orchard.", text_extracted_at: Time.current,
                        summary_long: "Old.", summarized_at: 1.hour.ago)
    previous = ENV["HOUSE_INFERENCE_OPENROUTER_API_KEY"]
    ENV["HOUSE_INFERENCE_OPENROUTER_API_KEY"] = "test-key"
    FieldSummaries.live = true

    assert_enqueued_with(job: FieldItems::SummarizeJob) do
      post resummarize_account_field_file_path(@account, file)
    end
    assert_response :redirect
    get account_field_path(@account, tab: "files", item: "file-#{file.to_param}")
    item = inertia_props["items"].find { |i| i["id"] == file.to_param }
    assert_equal [ true, "Old." ], item.values_at("summary_pending", "summary_long")
    assert_equal resummarize_account_field_file_path(@account, file), item["resummarize_url"]
  ensure
    ENV["HOUSE_INFERENCE_OPENROUTER_API_KEY"] = previous
    FieldSummaries.live = false
  end

  private

  def inertia_props
    JSON.parse(Nokogiri::HTML(response.body).at_css("[data-page]")&.[]("data-page") || response.body)["props"]
  end

end

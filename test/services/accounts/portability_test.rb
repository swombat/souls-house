require "test_helper"
require "zip"

# Account export and import (docs/features/account-portability.md). The
# resident archive itself is covered by the resident portability tests; here
# the resident export/import seams are stubbed and everything else is real.
class Accounts::PortabilityTest < ActiveSupport::TestCase

  include ActiveJob::TestHelper

  setup do
    @user = users(:user_1)
    @source = accounts(:personal_account)
    @resident = agents(:research_assistant)
    @running = agents(:code_reviewer)
    @destination = Account.create!(name: "Destination #{SecureRandom.hex(3)}", account_type: "team")
    @destination.memberships.create!(user: @user, role: "owner", confirmed_at: Time.current)

    @resident.reflexes.create!(name: "Done but not", shape: "Does the post say it is done?", reminder: "Say which part is done.")
    @room = @source.rooms.create!(name: "Workshop #{SecureRandom.hex(2)}", description: "Where things get built")
    RoomModelDefault.create!(account: @source, room: @room, agent: @resident, model_id: @resident.model_id)
    @file = @source.field_files.create!(file: fixture_file("test.txt", "text/plain"), title: "Receipts", note: "From the drawer",
      uploaded_by: @user, dated_at: Time.utc(2025, 3, 1))
    @file.change_tags!(by: @user, set: [ "dad" ])
    @song = @source.field_songs.create!(title: "Partita", artist: "Bach", instrumental: true, added_by: @resident, links: [ "https://www.youtube.com/watch?v=abc123" ])
    @note = @source.whiteboards.create!(name: "Week notes", content: "The Bach partita, slowly")
    @rhythm = Rhythm.create!(account: @source, creator: @user, title: "Morning", opening: "What's today?", cadence: "daily",
      time_of_day: "08:30", timezone: "Madrid", agents: [ @resident ])
    @source.transcription_glossary_terms.create!(term: "GrantTree", pinned: true)
    @chat = @source.chats.create!(title: "Plans", room: @room, model_id_string: "openrouter/auto")
    @chat.chat_agents.create!(agent: @resident)
    Message.insert_all!([
      { chat_id: @chat.id, role: "user", content: "Can you look this up?", user_id: @user.id, agent_id: nil, created_at: 2.days.ago, updated_at: 2.days.ago, tools_used: [] },
      { chat_id: @chat.id, role: "assistant", content: "Here it is.", agent_id: @resident.id, user_id: nil, created_at: 1.day.ago, updated_at: 1.day.ago, tools_used: [] }
    ])
  end

  def fixture_file(name, type)
    Rack::Test::UploadedFile.new(Rails.root.join("test/fixtures/files", name), type)
  end

  # Resident export: one resident exportable, every other one "running".
  def with_resident_seams
    unavailable = ->(agent) { agent == @resident ? nil : "V1 requires an inactive, paused hosted resident" }
    export = lambda do |_agent, exporter:, &block|
      Dir.mktmpdir do |dir|
        path = File.join(dir, "resident.tar.gz")
        File.binwrite(path, "synthetic resident archive")
        block.call(path)
      end
    end
    Agents::Portability::Export.stub(:unavailable_reason, unavailable) do
      Agents::Portability::Export.stub(:call, export) { yield }
    end
  end

  def with_resident_import_seams(&block)
    @inner_export_id = SecureRandom.uuid
    @resident_imports = 0
    inner = Struct.new(:manifest).new({ "export_id" => @inner_export_id })
    with_upload = ->(file, &inner_block) { assert_equal "synthetic resident archive", file.read; inner_block.call(inner) }
    import = lambda do |_inner, account:, user:, name:|
      @resident_imports += 1
      account.agents.create!(name: name, runtime: "offline", model_id: "openrouter/auto", active: false, paused: true,
        system_prompt: "x", portability_custody: { "export_id" => @inner_export_id })
    end
    Agents::Portability::Archive.stub(:with_upload, with_upload) do
      Agents::Portability::Import.stub(:call, import) do
        Billing::BirthGate.stub(:import_refusal, nil, &block)
      end
    end
  end

  def export_zip(conversations: false)
    bytes = nil
    manifest = nil
    with_resident_seams do
      Accounts::Portability::Export.call(@source, exporter: @user, conversations:) do |path, m|
        bytes = File.binread(path)
        manifest = m
      end
    end
    [ bytes, manifest ]
  end

  def previewed_import(bytes)
    import = @destination.account_imports.create!(user: @user)
    import.upload.attach(io: StringIO.new(bytes), filename: "a.zip", content_type: "application/zip")
    AccountPortability::ValidateJob.perform_now(import.id)
    import.reload
  end

  def run_import(import)
    import.update!(status: "importing")
    with_resident_import_seams { AccountPortability::ImportJob.perform_now(import.id) }
    import.reload
  end

  test "an account round-trips into an empty account: residents stopped, Field, setup held, nothing running" do
    bytes, manifest = export_zip
    assert manifest["partial"], "a skipped running resident makes the export partial"
    skipped = manifest["residents"].find { |r| r["name"] == @running.name }
    assert_equal "skipped", skipped["status"]
    assert_match(/inactive, paused/, skipped["reason"])
    refute manifest.dig("options", "conversations")
    refute_includes manifest["inventory"].keys.join(" "), "conversations/"
    assert @running.reload.active?, "export never stops a resident"

    import = previewed_import(bytes)
    assert_equal "previewed", import.status, import.error
    assert_equal Digest::SHA256.hexdigest(bytes), import.archive_sha256
    assert_equal import.archive_sha256, import.preview["sha256"]
    assert import.preview["same_installation"]
    assert_nil import.preview["destination_refusal"]
    assert_equal 1, import.preview.dig("field", "files")

    assert_no_enqueued_jobs(only: [ AiResponseJob, MessageHandoffJob ]) do
      import = run_import(import)
    end
    assert_equal "imported", import.status, import.error

    agent = @destination.agents.sole
    assert_equal @resident.name, agent.name
    refute agent.active?
    assert agent.paused?
    reflex = agent.reflexes.sole
    assert reflex.held?
    assert_empty agent.reflexes.live

    room = @destination.rooms.find_by!(name: @room.name)
    assert_equal "Where things get built", room.description
    assert_equal @resident.model_id, RoomModelDefault.find_by!(account: @destination, agent: agent, room: room).model_id

    file = @destination.field_files.sole
    assert_equal "Receipts", file.title
    assert_equal "From the drawer", file.note
    assert_equal File.binread(Rails.root.join("test/fixtures/files/test.txt")), file.file.download
    assert_equal [ "dad" ], file.tag_names
    assert_equal @user, file.uploaded_by, "a person's upload is attributed to the importer, never matched by name"
    assert_equal agent, @destination.field_songs.sole.added_by
    assert_equal "The Bach partita, slowly", @destination.whiteboards.find_by!(name: "Week notes").content

    rhythm = Rhythm.find_by!(account: @destination)
    assert rhythm.held?
    assert_equal [ agent ], rhythm.agents.to_a
    assert @destination.transcription_glossary_terms.exists?(term: "GrantTree", pinned: true)
    assert_empty @destination.chats, "conversations travel only when chosen"
    assert_equal 0, @destination.memberships.where.not(user: @user).count

    summary = import.ledger["summary"]
    assert_equal 1, summary["residents"]
    assert summary["residents_skipped"].all? { |s| s["reason"].start_with?("Not in the archive") }
    assert AuditLog.exists?(action: "import_account_archive", account: @destination)
  end

  test "conversations travel only when chosen, archived, and inserting them wakes nobody" do
    bytes, manifest = export_zip(conversations: true)
    assert manifest.dig("options", "conversations")
    assert_includes manifest["warnings"], Accounts::Portability::Archive::CONVERSATIONS_WARNING
    import = previewed_import(bytes)
    assert_operator import.preview["conversations"], :>=, 1

    assert_no_enqueued_jobs(only: [ AiResponseJob, MessageHandoffJob, GenerateTitleJob ]) do
      import = run_import(import)
    end
    assert_equal "imported", import.status, import.error
    chat = @destination.chats.find_by!(title: "Plans")
    assert chat.archived_at.present?
    agent = @destination.agents.sole
    assert_equal [ agent ], chat.agents.to_a
    human, reply = chat.messages.order(:created_at).to_a
    assert_nil human.user_id, "no user is attached by name or email"
    assert_equal "**#{@user.display_name}:** Can you look this up?", human.content
    assert_equal agent, reply.agent
    assert_equal "Here it is.", reply.content
  end

  test "a retried import creates nothing twice" do
    bytes, = export_zip(conversations: true)
    import = run_import(previewed_import(bytes))
    assert_equal "imported", import.status, import.error
    counts = -> { [ @destination.agents.count, @destination.field_files.count, @destination.field_songs.count, @destination.whiteboards.count,
                    Rhythm.where(account: @destination).count, @destination.chats.count, Message.joins(:chat).where(chats: { account_id: @destination.id }).count ] }
    before = counts.call
    import.update!(status: "importing")
    import.upload.attach(io: StringIO.new(bytes), filename: "a.zip", content_type: "application/zip")
    with_resident_import_seams { AccountPortability::ImportJob.perform_now(import.id) }
    assert_equal "imported", import.reload.status, import.error
    assert_equal before, counts.call
    assert_equal 0, @resident_imports, "the ledger skips the resident without touching the resident import"
  end

  test "a crash after the resident's own commit finds that copy instead of making another" do
    bytes, = export_zip
    import = previewed_import(bytes)
    with_resident_import_seams do
      key = import.preview["residents"].find { |r| r["status"] == "included" }["key"]
      # What a crash leaves: the pending note, and the copy the resident import committed.
      import.update!(status: "importing", ledger: { "residents" => { key => { "export_id" => @inner_export_id } } })
      @destination.agents.create!(name: @resident.name, runtime: "offline", model_id: "openrouter/auto", active: false, paused: true,
        system_prompt: "x", portability_custody: { "export_id" => @inner_export_id })
      AccountPortability::ImportJob.perform_now(import.id)
    end
    assert_equal "imported", import.reload.status, import.error
    assert_equal 1, @destination.agents.count
    assert_equal 0, @resident_imports
  end

  test "the import refuses bytes other than the previewed ones" do
    bytes, = export_zip
    import = previewed_import(bytes)
    other, = export_zip
    import.upload.attach(io: StringIO.new(other), filename: "a.zip", content_type: "application/zip")
    import = run_import(import)
    assert_equal "failed", import.status
    assert_match(/not the one that was previewed/, import.error)
    assert_empty @destination.agents
  end

  test "an account with residents or Field items is not an import destination" do
    bytes, = export_zip
    @destination.whiteboards.create!(name: "Already here", content: "x")
    import = previewed_import(bytes)
    assert_match(/already has things in its Field/, import.preview["destination_refusal"])
    import = run_import(import)
    assert_equal "failed", import.status
    assert_empty @destination.agents
  end

  test "Field media over the per-entry limit is listed, never silently dropped" do
    Accounts::Portability::Export.stub(:media_limit, 4) do
      _bytes, manifest = export_zip
      assert manifest["partial"]
      omitted = manifest["omitted"].find { |o| o["kind"] == "file" }
      assert_equal "Receipts", omitted["title"]
      assert_match(/per-entry limit/, omitted["reason"])
    end
  end

  test "a non-ready recording travels with its audio and arrives failed with a reason" do
    recording = @source.field_recordings.new(title: "Dad, Sunday", uploaded_by: @user, status: "transcribing", duration_ms: 1_000)
    recording.audio.attach(fixture_file("test_audio.mp3", "audio/mpeg"))
    recording.save!(validate: false)
    bytes, manifest = export_zip
    refute manifest["omitted"].any? { |o| o["kind"] == "recording" }
    import = run_import(previewed_import(bytes))
    assert_equal "imported", import.status, import.error
    copy = @destination.field_recordings.sole
    assert_equal "failed", copy.status
    assert_equal "Imported before transcription finished", copy.failure_reason
    assert_equal recording.audio.download, copy.audio.download
  end

end

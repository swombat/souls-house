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

  def with_resident_import_seams(refusal: nil, &block)
    @inner_export_id ||= SecureRandom.uuid
    @resident_imports = 0
    inner = Struct.new(:manifest).new({ "export_id" => @inner_export_id })
    with_upload = lambda do |file, &inner_block|
      raise Agents::Portability::Error, "Invalid resident archive" unless file.read == "synthetic resident archive"
      inner_block.call(inner)
    end
    import = lambda do |_inner, account:, user:, name:|
      @resident_imports += 1
      account.agents.create!(name: name, runtime: "offline", model_id: "openrouter/auto", active: false, paused: true,
        system_prompt: "x", portability_custody: { "export_id" => @inner_export_id })
    end
    Agents::Portability::Archive.stub(:with_upload, with_upload) do
      Agents::Portability::Import.stub(:call, import) do
        Billing::BirthGate.stub(:import_refusal, refusal, &block)
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

  def previewed_import(bytes, valid_residents: true)
    import = @destination.account_imports.create!(user: @user)
    import.upload.attach(io: StringIO.new(bytes), filename: "a.zip", content_type: "application/zip")
    if valid_residents
      with_resident_import_seams { AccountPortability::ValidateJob.perform_now(import.id) }
    else
      AccountPortability::ValidateJob.perform_now(import.id)
    end
    import.reload
  end

  def run_import(import, refusal: nil)
    import.update!(status: "importing")
    with_resident_import_seams(refusal:) { AccountPortability::ImportJob.perform_now(import.id) }
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
    assert summary["partial"]
    assert_includes summary["not_in_archive"].map { |n| n["title"] }, @running.name
    assert_empty summary["failures"]
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


  test "imported Field items are held: no extraction, OCR or summary is queued, and the sweep skips them, until released" do
    pdf = @source.field_files.create!(file: fixture_file("test_document.pdf", "application/pdf"), title: "Scan")
    pdf.update_columns(pdf_status: "extracted", pdf_page_count: 1, pdf_coverage: { "listed" => 1, "text" => 0, "ocr" => "pending" },
      extracted_text: "")
    pdf.pages.create!(page_number: 1, native_status: "empty")
    recording = @source.field_recordings.new(title: "Ready, never summarised", uploaded_by: @user, status: "ready", duration_ms: 1_000,
      transcript_source: "supplied", transcript_text: "Hello there", transcript_turns: [ { "spk" => "spk0", "t" => "Hello there" } ])
    recording.audio.attach(fixture_file("test_audio.mp3", "audio/mpeg"))
    recording.save!(validate: false)
    bytes, = export_zip
    import = previewed_import(bytes)
    clear_enqueued_jobs
    FieldSummaries.stub(:enabled?, true) do
      FieldOcr.stub(:eligible?, true) do
        import = run_import(import)
        assert_equal "imported", import.status, import.error
        held = [ FieldItems::SummarizeJob, FieldFiles::ExtractTextJob, FieldFiles::ExtractPdfJob, FieldFiles::OcrPdfJob ]
        assert enqueued_jobs.none? { |job| held.map(&:name).include?(job["job_class"]) }, "an import queued automatic reading"
        FieldItems::SummarySweepJob.perform_now
        imported = (@destination.field_files.to_a + @destination.field_recordings.to_a).map { |item| item.to_global_id.to_s }
        swept = enqueued_jobs.select { |job| job["job_class"] == "FieldItems::SummarizeJob" }.map { |job| job["arguments"].first["_aj_globalid"] }
        assert_empty swept & imported, "the summary sweep reached a held item"

        copy = @destination.field_files.find_by!(title: "Scan")
        assert copy.import_held?
        assert_equal "extracted", copy.pdf_status
        assert_equal [ "empty" ], copy.pages.map(&:native_status)
        refute copy.transcribe_pdf!, "OCR refuses a held item"
        refute copy.claim_summary!
        rec = @destination.field_recordings.find_by!(title: "Ready, never summarised")
        assert rec.import_held?
        refute_includes FieldRecording.summary_due.to_a, rec

        assert_enqueued_with(job: FieldItems::SummarizeJob) { rec.release_import_hold! }
        assert_enqueued_with(job: FieldFiles::OcrPdfJob) { copy.release_import_hold! }
        refute rec.reload.import_held?
      end
    end
  end

  test "speakers round-trip by archive-local voice: shared labels stay shared, a clashing name is never matched" do
    ana = @source.field_voices.create!(name: "Ana")
    bea = @source.field_voices.create!(name: "Bea")
    recording = @source.field_recordings.new(title: "Three voices", uploaded_by: @user, status: "ready", duration_ms: 3_000,
      transcript_source: "supplied", transcript_text: "a b c",
      transcript_turns: [ { "spk" => "spk0", "t" => "one" }, { "spk" => "spk1", "t" => "two" }, { "spk" => "spk2", "t" => "three" } ])
    recording.audio.attach(fixture_file("test_audio.mp3", "audio/mpeg"))
    recording.save!(validate: false)
    recording.speakers.create!(label: "spk0", position: 0, field_voice: ana, naming_source: "human")
    recording.speakers.create!(label: "spk1", position: 1, field_voice: bea, naming_source: "human")
    recording.speakers.create!(label: "spk2", position: 2, field_voice: ana, naming_source: "human")
    already = @destination.field_voices.create!(name: "Ana")

    bytes, = export_zip
    import = run_import(previewed_import(bytes))
    assert_equal "imported", import.status, import.error
    copy = @destination.field_recordings.find_by!(title: "Three voices")
    speakers = copy.speakers.to_a
    assert_equal %w[spk0 spk1 spk2], speakers.map(&:label)
    assert_equal speakers[0].field_voice_id, speakers[2].field_voice_id
    refute_equal speakers[0].field_voice_id, speakers[1].field_voice_id
    refute_includes speakers.map(&:field_voice_id), already.id
    assert speakers.all?(&:sample_excluded?)
    refute speakers.any?(&:training_label?), "imported names give no voice print anything to learn from"
    assert_equal [ "Ana (2)", "Bea", "Ana (2)" ], copy.transcript_lines.map { |line| line[:speaker] }
  end

  test "two archive voices with one name stay two voices" do
    bytes, = export_zip
    import = previewed_import(bytes)
    importer = Accounts::Portability::Import.new(nil, import)
    importer.instance_variable_set(:@archive, Struct.new(:field).new({ "voices" => [ { "key" => "v1", "name" => "Cy" }, { "key" => "v2", "name" => "Cy" } ] }))
    first = importer.send(:voice_for, "v1")
    second = importer.send(:voice_for, "v2")
    refute_equal first, second
    assert_equal [ "Cy", "Cy (2)" ], [ first.name, second.name ]
    assert_equal first, importer.send(:voice_for, "v1")
  end

  test "a resident whose own archive is invalid is shown before confirming and never reaches the resident import" do
    bytes, = export_zip
    import = previewed_import(bytes, valid_residents: false)
    resident = import.preview["residents"].find { |r| r["name"] == @resident.name }
    assert_equal "invalid", resident["status"]
    assert_match(/not valid/, resident["reason"])
    import.update!(status: "importing")
    Agents::Portability::Import.stub(:call, ->(*, **) { flunk "an invalid resident archive must not be imported" }) do
      AccountPortability::ImportJob.perform_now(import.id)
    end
    assert_equal "imported", import.reload.status, import.error
    assert_empty @destination.agents
    assert import.ledger.dig("summary", "not_in_archive").any? { |n| n["title"] == @resident.name }
  end

  test "a refused resident is a recoverable failure: reported, not ledgered, and created by Retry" do
    bytes, = export_zip
    import = run_import(previewed_import(bytes), refusal: "This account's plan does not include another resident")
    assert_equal "imported", import.status, import.error
    failure = import.ledger.dig("summary", "failures").find { |f| f["kind"] == "resident" }
    assert_equal "resident", failure["kind"]
    assert_match(/plan does not include/, failure["reason"])
    assert_includes import.ledger.dig("summary", "failures").map { |f| f["reason"] }, "None of its residents arrived"
    assert_empty @destination.agents
    import = run_import(import)
    assert_equal 1, @destination.agents.count
    assert_empty import.ledger.dig("summary", "failures")
  end

  test "a second worker for an account already importing waits instead of creating" do
    bytes, = export_zip
    import = previewed_import(bytes)
    import.update!(status: "importing")
    # Another worker's session, outside the test's own connection.
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    other = PG.connect(host: config[:host], port: config[:port], dbname: config[:database], user: config[:username], password: config[:password])
    other.exec_params("SELECT pg_advisory_lock($1, $2)", [ Accounts::Portability::Import::LOCK_CLASS, @destination.id ])
    assert_enqueued_with(job: AccountPortability::ImportJob, args: [ import.id ]) do
      with_resident_import_seams { AccountPortability::ImportJob.perform_now(import.id) }
    end
    assert_equal "importing", import.reload.status
    assert_empty @destination.agents
    assert_empty @destination.field_files
  ensure
    other&.close
  end

end

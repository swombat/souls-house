require "digest"
require "tmpdir"

module Accounts::Portability
  # Builds one account archive (Archive::FORMAT) into a private temporary
  # directory and yields its path. Residents travel as their own unchanged
  # resident archives (Agents::Portability::Export); a resident that cannot be
  # exported now (running, imported home, erased graph...) is listed with the
  # resident export's own reason and never stopped. Anything else that cannot
  # travel is listed with a reason too, and any such entry makes the archive
  # partial. Nothing secret is read: service connections travel as provider,
  # label and kind only.
  class Export

    MESSAGE_ROLES = %w[user assistant].freeze

    def self.call(account, exporter:, conversations: false, progress: ->(_step, _done, _total) { }, &block)
      new(account, exporter:, conversations:, progress:).call(&block)
    end

    def self.media_limit = Archive::MAX_ENTRY

    def initialize(account, exporter:, conversations:, progress:)
      @account, @exporter, @include_conversations, @progress = account, exporter, conversations == true, progress
      @entries = {}
      @omitted = []
      @resident_keys = {}
    end

    def call
      Dir.mktmpdir("account-export-") do |dir|
        File.chmod(0700, dir)
        @stage = File.join(dir, "stage")
        Dir.mkdir(@stage, 0700)
        residents = export_residents
        export_field
        export_setup
        export_conversations if @include_conversations
        add_file("README.md", readme)
        manifest = {
          "format" => Archive::FORMAT,
          "export_id" => SecureRandom.uuid,
          "created_at" => Time.current.iso8601,
          "source_application" => "souls.house",
          "source_installation" => Digest::SHA256.hexdigest(Agents::Config.internal_url),
          "account_name" => @account.name.to_s.truncate(200),
          "exported_by" => @exporter.to_param.to_s,
          "options" => { "conversations" => @include_conversations },
          "partial" => residents.any? { |r| r["status"] == "skipped" } || @omitted.any?,
          "residents" => residents,
          "omitted" => @omitted,
          "never_travels" => NEVER_TRAVELS,
          "warnings" => Archive::WARNINGS + (@include_conversations ? [ Archive::CONVERSATIONS_WARNING ] : []),
          "limits" => Archive.limits.transform_keys(&:to_s),
          "inventory" => @entries.deep_dup
        }
        add_json("manifest.json", manifest)
        @progress.call("packing", 0, 1)
        output = File.join(dir, "account.zip")
        Archive.pack(@stage, @entries, output)
        # Our own output must pass the same hostile-input boundary.
        File.open(output, "rb") { |file| Archive.with_file(file) { |_| } }
        yield output, manifest
      end
    end

    NEVER_TRAVELS = [
      "provider credentials, API keys and service-connection secrets",
      "Chaos and private state volumes, runtime session databases",
      "billing and plan state",
      "members, invitations, guest seats and integration grants",
      "approval grants and VM identities",
      "voiceprints and voice samples",
      "tweets collected into the Field",
      "forgotten (discarded) items, residents' forgotten reflexes"
    ].freeze

    private

    def export_residents
      agents = @account.agents.order(:id).to_a
      agents.each_with_index.map do |agent, index|
        key = "r#{index + 1}"
        @resident_keys[agent.id] = key
        @progress.call("residents", index, agents.length)
        reason = Agents::Portability::Export.unavailable_reason(agent)
        if reason
          next { "key" => key, "name" => agent.name.to_s.truncate(200), "status" => "skipped", "reason" => reason }
        end
        archive_path = "residents/#{key}.tar.gz"
        begin
          Agents::Portability::Export.call(agent, exporter: @exporter) do |path|
            target = File.join(@stage, archive_path)
            FileUtils.mkdir_p(File.dirname(target), mode: 0700)
            FileUtils.cp(path, target)
            File.chmod(0600, target)
            record(archive_path)
          end
        rescue Agents::Portability::Error, Agents::Resources::OwnershipError, ActiveRecord::LockWaitTimeout => error
          FileUtils.rm_f(File.join(@stage, archive_path))
          @entries.delete(archive_path)
          next { "key" => key, "name" => agent.name.to_s.truncate(200), "status" => "skipped",
                 "reason" => error.message.presence || "Resident export failed" }
        end
        reflexes = agent.reflexes.kept.order(:id).map { |r| r.slice(:name, :shape, :reminder).transform_keys(&:to_s) }
        add_json("residents/#{key}.json", { "reflexes" => reflexes })
        { "key" => key, "name" => agent.name.to_s.truncate(200), "status" => "included", "archive" => archive_path }
      end
    end

    def export_field
      tags = @account.field_tags.kept.order(:id).to_a
      @tag_keys = tags.each_with_index.to_h { |tag, i| [ tag.id, "t#{i + 1}" ] }
      index = { "tags" => tags.map { |t| { "key" => @tag_keys[t.id], "name" => t.name } } }
      kinds = {
        "files" => @account.field_files.kept.order(:id),
        "recordings" => @account.field_recordings.kept.order(:id),
        "songs" => @account.field_songs.kept.order(:id),
        "notes" => @account.whiteboards.where(deleted_at: nil).order(:id)
      }
      kinds.each do |kind, scope|
        total = scope.count
        index[kind] = []
        scope.find_each.with_index do |item, i|
          @progress.call("field #{kind}", i, total)
          key = "#{kind[0]}#{i + 1}"
          doc = send(:"#{kind}_doc", item)
          media = media_for(kind, item)
          if media.is_a?(String)
            @omitted << { "kind" => kind.singularize, "title" => doc["title"].to_s.truncate(200), "reason" => media }
            next
          end
          doc["media"] = media && write_media(kind, key, media)
          doc["tags"] = taggings_for(item)
          add_json("field/#{kind}/#{key}/item.json", doc)
          index[kind] << key
        end
      end
      index["voices"] = (@voices || {}).values
      add_json("field/index.json", index)
    end

    # Returns the attachment, nil (nothing attached), or a reason string.
    def media_for(kind, item)
      attachment = case kind
      when "files" then item.file
      when "recordings", "songs" then item.audio
      end
      return nil unless attachment&.attached?
      return "Media larger than the account archive's per-entry limit (#{Archive::MAX_ENTRY / 1.gigabyte} GiB)" if attachment.blob.byte_size > self.class.media_limit
      attachment
    end

    def write_media(kind, key, attachment)
      path = "field/#{kind}/#{key}/media"
      target = File.join(@stage, path)
      FileUtils.mkdir_p(File.dirname(target), mode: 0700)
      File.open(target, "wb", 0600) { |out| attachment.blob.download { |chunk| out.write(chunk) } }
      record(path)
      { "filename" => attachment.blob.filename.to_s.truncate(255), "content_type" => attachment.blob.content_type.to_s.truncate(255),
        "byte_size" => @entries[path]["size"], "sha256" => @entries[path]["sha256"] }
    rescue ActiveStorage::FileNotFoundError
      FileUtils.rm_f(target)
      @entries.delete(path)
      @omitted << { "kind" => kind.singularize, "title" => "#{kind.singularize} #{key}", "reason" => "Stored media is missing; metadata travelled without it" }
      nil
    end

    def taggings_for(item)
      return [] unless item.respond_to?(:field_taggings)
      item.field_taggings.kept.filter_map { |tagging| @tag_keys[tagging.field_tag_id] }.uniq
    end

    def author(record)
      case record
      when Agent then @resident_keys[record.id] ? { "type" => "resident", "key" => @resident_keys[record.id] } : { "type" => "name", "name" => record.name.to_s.truncate(200) }
      when User then { "type" => "name", "name" => record.display_name.to_s.truncate(200) }
      end
    end

    def common(item, title)
      { "title" => title, "created_at" => item.created_at&.iso8601,
        "dated_at" => item.respond_to?(:dated_at) ? item.dated_at&.iso8601 : nil }
    end

    def files_doc(file)
      common(file, file.title).merge(
        "author" => author(file.uploaded_by), "note" => file.note, "extracted_text" => file.extracted_text,
        "text_extracted_at" => file.text_extracted_at&.iso8601,
        "pdf_status" => file.pdf_status, "pdf_status_reason" => file.pdf_status_reason, "pdf_page_count" => file.pdf_page_count,
        "pdf_coverage" => file.pdf_coverage,
        "pages" => file.pages.map { |page| FieldFile::PdfExtraction::PAGE_COLUMNS.to_h { |c| [ c.to_s, page[c] ] } },
        "summary_short" => file.summary_short, "summary_long" => file.summary_long, "summarized_at" => file.summarized_at&.iso8601,
        "summary_input_digest" => file.summary_input_digest
      )
    end

    RECORDING_FIELDS = %w[note notes status failure_reason expected_speakers duration_ms transcript_words transcript_text transcript_turns
      language_code transcript_source source_path summary_short summary_long summary_input_digest].freeze

    def recordings_doc(recording)
      common(recording, recording.title).merge(recording.attributes.slice(*RECORDING_FIELDS)).merge(
        "author" => author(recording.uploaded_by), "recorded_at" => recording.recorded_at&.iso8601,
        "ready_at" => recording.ready_at&.iso8601, "summarized_at" => recording.summarized_at&.iso8601,
        "speakers" => recording.speakers.includes(:field_voice).map { |speaker| speaker_doc(speaker) }
      )
    end

    SPEAKER_FIELDS = %w[label position talk_ms clip_start_ms clip_end_ms ignored_as].freeze

    # A speaker's grouping and name, never its embedding, samples or the
    # people who decided. Voices are archive-local keys: two source voices
    # with one name stay two, two labels on one voice stay on one.
    def speaker_doc(speaker)
      voice = speaker.field_voice&.kept? ? speaker.field_voice : nil
      speaker.attributes.slice(*SPEAKER_FIELDS).merge("ignored" => speaker.ignored_at.present?, "voice_key" => voice && voice_key(voice))
    end

    def voice_key(voice)
      @voices ||= {}
      @voices[voice.id] ||= { "key" => "v#{@voices.length + 1}", "name" => voice.name.to_s.truncate(FieldVoice::MAX_NAME_LENGTH) }
      @voices[voice.id]["key"]
    end

    SONG_FIELDS = %w[artist album year links lyrics instrumental note duration_ms].freeze

    def songs_doc(song)
      common(song, song.title).merge(song.attributes.slice(*SONG_FIELDS)).merge("author" => author(song.added_by))
    end

    def notes_doc(board)
      common(board, board.name).merge("content" => board.content, "summary" => board.summary,
        "author" => author(board.last_edited_by))
    end

    def export_setup
      rooms = @account.rooms.to_a
      @room_keys = rooms.each_with_index.to_h { |room, i| [ room.id, "m#{i + 1}" ] }
      setup = {
        "rooms" => rooms.map { |room| { "key" => @room_keys[room.id], "name" => room.name, "description" => room.description } },
        "room_model_defaults" => @account.room_model_defaults.filter_map do |default|
          next unless @resident_keys[default.agent_id]
          { "room_key" => default.room_id && @room_keys[default.room_id], "resident_key" => @resident_keys[default.agent_id], "model_id" => default.model_id }
        end,
        "rhythms" => Rhythm.where(account: @account).includes(:rhythm_agents).order(:id).each_with_index.map do |rhythm, i|
          rhythm.attributes.slice(*%w[title append_date opening cadence time_of_day weekday month_day month timezone room_choice]).merge(
            "key" => "y#{i + 1}", "room_key" => rhythm.room_id && @room_keys[rhythm.room_id],
            "resident_keys" => rhythm.rhythm_agents.filter_map { |ra| @resident_keys[ra.agent_id] }
          )
        end,
        "glossary" => @account.transcription_glossary_terms.where(suppressed_at: nil).order(:id).map { |t| { "term" => t.term, "pinned" => t.pinned } },
        "services" => @account.service_connections.order(:id).map do |connection|
          { "provider" => connection.provider, "label" => connection.label.to_s.truncate(200), "kind" => connection.credential_kind }
        end
      }
      add_json("setup.json", setup)
    end

    def export_conversations
      chats = @account.chats.kept.order(:id)
      total = chats.count
      keys = []
      chats.find_each.with_index do |chat, i|
        @progress.call("conversations", i, total)
        key = "c#{i + 1}"
        messages = chat.messages.where(discarded_at: nil, role: MESSAGE_ROLES, progress_message: false).order(:created_at, :id)
          .includes(:user, :agent).map do |message|
            { "role" => message.role, "author" => author(message.agent || message.user), "content" => message.content.to_s,
              "created_at" => message.created_at.iso8601 }
          end
        doc = { "title" => chat.title.to_s.truncate(200), "room_key" => chat.room_id && @room_keys[chat.room_id],
                "created_at" => chat.created_at.iso8601, "resident_keys" => chat.chat_agents.filter_map { |ca| @resident_keys[ca.agent_id] },
                "messages" => messages }
        body = JSON.generate(doc)
        if body.bytesize > Archive::MAX_JSON
          @omitted << { "kind" => "conversation", "title" => doc["title"], "reason" => "Transcript larger than #{Archive::MAX_JSON / 1.megabyte} MiB" }
          next
        end
        add_file("conversations/#{key}.json", body)
        keys << key
      end
      add_json("conversations/index.json", keys)
    end

    def add_json(path, object)
      body = JSON.generate(object)
      raise Error, "#{path} exceeds the archive's JSON limit" if body.bytesize > Archive::MAX_JSON
      add_file(path, body)
    end

    def add_file(path, body)
      target = File.join(@stage, path)
      FileUtils.mkdir_p(File.dirname(target), mode: 0700)
      File.write(target, body, mode: "wb", perm: 0600)
      @entries[path] = { "size" => body.bytesize, "sha256" => Digest::SHA256.hexdigest(body) }
    end

    def record(path)
      file = File.join(@stage, path)
      @entries[path] = { "size" => File.size(file), "sha256" => Digest::SHA256.file(file).hexdigest }
      raise Error, "Account archive exceeds its entry limit" if @entries.length > Archive::MAX_ENTRIES - 10
      raise Error, "Account archive exceeds its expanded limit" if @entries.values.sum { |e| e["size"] } > Archive::MAX_EXPANDED
    end

    def readme
      <<~TEXT
        souls.house account archive (#{Archive::FORMAT})

        #{(Archive::WARNINGS + (@include_conversations ? [ Archive::CONVERSATIONS_WARNING ] : [])).join("\n\n")}

        Layout
          manifest.json            what travelled, what did not and why, and a SHA-256
                                   inventory of every member
          residents/<key>.tar.gz   each exported resident's own archive (souls-resident/v1),
                                   unchanged; it has its own README inside
          residents/<key>.json     that resident's live reflexes (they arrive held)
          field/index.json         the Field: files, recordings, songs, notes and tags
          field/<kind>/<key>/      item.json (metadata, transcript, summary, note, tags)
                                   and media (the original bytes, where any exist)
          setup.json               rooms, rooms' model defaults, rhythms (they arrive held),
                                   the transcription glossary, and the names and kinds of
                                   service connections to reconnect
          conversations/           only when conversations were chosen: message text with
                                   authors as names; no attachments, tool calls or state

        Never in this archive: #{NEVER_TRAVELS.join("; ")}.

        Limits: #{Archive::MAX_COMPRESSED / 1.gigabyte} GiB compressed, #{Archive::MAX_EXPANDED / 1.gigabyte} GiB expanded,
        #{Archive::MAX_ENTRIES} members, #{Archive::MAX_ENTRY / 1.gigabyte} GiB per member, #{Archive::MAX_JSON / 1.megabyte} MiB per JSON document.
        Everything can be read offline. Do not run archived code merely to inspect it.
      TEXT
    end

  end
end

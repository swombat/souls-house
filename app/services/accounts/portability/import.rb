module Accounts::Portability
  # Rebuilds a validated account archive inside an empty account. Every part
  # is created at most once: each created record's id is written to the
  # AccountImport's ledger under its archive key in the same transaction as
  # the record, so a retried job skips what already exists. Residents go
  # through the resident import (they arrive stopped and paused); rhythms
  # arrive held and reflexes arrive held; conversations arrive archived, with
  # their messages inserted directly so nothing wakes, hands off or replays.
  # People never travel: a person's name stays as attribution text, and no
  # existing user is matched by name or email.
  class Import

    def self.destination_refusal(account, import: nil)
      entries = import ? import.ledger.fetch("residents", {}).values.select { |v| v.is_a?(Hash) } : []
      created = entries.filter_map { |v| v["agent_id"] }
      pending = entries.filter_map { |v| v["export_id"] }
      others = account.agents.where.not(id: created)
      others = others.where("portability_custody ->> 'export_id' IS NULL OR portability_custody ->> 'export_id' NOT IN (?)", pending) if pending.any?
      return "This account already has residents. Import into a new, empty account." if others.exists?
      field = import ? import.ledger.fetch("field", {}) : {}
      kinds = { "files" => account.field_files.kept, "recordings" => account.field_recordings.kept,
                "songs" => account.field_songs.kept, "notes" => account.whiteboards.where(deleted_at: nil) }
      if kinds.any? { |kind, scope| scope.where.not(id: field.fetch(kind, {}).values).exists? }
        return "This account already has things in its Field. Import into a new, empty account."
      end
      nil
    end

    def self.call(archive, import:)
      new(archive, import).call
    end

    def initialize(archive, import)
      @archive, @import = archive, import
      @account, @user = import.account, import.user
    end

    def call
      raise Error, "The archive is not the one that was previewed" unless @archive.sha256 == @import.archive_sha256
      if (refusal = self.class.destination_refusal(@account, import: @import))
        raise Error, refusal
      end
      import_residents
      import_rooms
      import_room_model_defaults
      import_glossary
      import_field
      import_rhythms
      import_conversations
      summary = summarise
      write_ledger("summary", summary)
      summary
    end

    private

    def ledger(section) = @import.reload.ledger.fetch(section, {})

    # Writes one ledger entry. Called inside the creating transaction, so the
    # record and the note that it exists commit together.
    def note!(section, key, value)
      @import.with_lock do
        ledger = @import.ledger.deep_dup
        (ledger[section] ||= {})[key] = value
        @import.update_columns(ledger: ledger, updated_at: Time.current)
      end
    end

    def write_ledger(section, value)
      @import.with_lock do
        @import.update_columns(ledger: @import.ledger.merge(section => value), updated_at: Time.current)
      end
    end

    def skip!(section, key, reason)
      note!(section, key, { "skipped" => reason.to_s.truncate(500) })
    end

    def resident_ids
      @resident_ids ||= ledger("residents").filter_map { |key, v| [ key, v["agent_id"] ] if v.is_a?(Hash) && v["agent_id"] }.to_h
    end

    def agent_for(key)
      id = resident_ids[key]
      id && @account.agents.find_by(id: id)
    end

    def import_residents
      @archive.manifest["residents"].each do |resident|
        key = resident["key"]
        entry = ledger("residents")[key]
        next if entry && !(entry.is_a?(Hash) && entry.keys == [ "export_id" ])
        if resident["status"] == "skipped"
          skip!("residents", key, "Not in the archive: #{resident["reason"]}")
          next
        end
        if (refusal = Billing::BirthGate.import_refusal(@account))
          skip!("residents", key, refusal)
          next
        end
        File.open(@archive.path(resident["archive"]), "rb") do |file|
          Agents::Portability::Archive.with_upload(file) do |inner|
            export_id = inner.manifest["export_id"]
            # Noted before the resident import commits on its own, so a retry
            # after a crash in between finds that copy instead of making another.
            note!("residents", key, { "export_id" => export_id })
            agent = @account.agents.find_by("portability_custody ->> 'export_id' = ?", export_id)
            agent ||= Agents::Portability::Import.call(inner, account: @account, user: @user, name: unique_name(resident["name"]))
            Agent.transaction do
              @resident_ids = nil
              note!("residents", key, { "agent_id" => agent.id, "export_id" => export_id })
              held_reflexes(agent, key)
            end
          end
        end
      rescue Agents::Portability::Error, Agents::Resources::OwnershipError => error
        skip!("residents", key, error.message.presence || "Resident import failed")
      end
      @resident_ids = nil
    end

    def held_reflexes(agent, key)
      return if agent.reflexes.exists?
      @archive.resident_extra(key).fetch("reflexes", []).each do |reflex|
        agent.reflexes.create!(reflex.slice("name", "shape", "reminder").merge("held_at" => Time.current))
      end
    end

    def unique_name(name)
      taken = @account.agents.pluck(:name).map(&:downcase)
      candidate = name
      n = 1
      while taken.include?(candidate.downcase)
        n += 1
        candidate = "#{name} (#{n})"
      end
      candidate
    end

    def import_rooms
      @archive.setup["rooms"].each do |room_doc|
        key = room_doc["key"]
        next if ledger("rooms").key?(key)
        Room.transaction do
          room = @account.rooms.where("lower(name) = ?", room_doc["name"].downcase).first ||
            @account.rooms.create!(name: room_doc["name"], description: room_doc["description"])
          note!("rooms", key, room.id)
        end
      rescue ActiveRecord::RecordInvalid => error
        skip!("rooms", key, error.record.errors.full_messages.to_sentence)
      end
    end

    def room_id(key) = key && ledger("rooms")[key].is_a?(Integer) ? ledger("rooms")[key] : nil

    def import_room_model_defaults
      return if ledger("progress").key?("room_model_defaults")
      RoomModelDefault.transaction do
        @archive.setup["room_model_defaults"].each do |doc|
          agent = agent_for(doc["resident_key"])
          next unless agent
          next if doc["room_key"] && !room_id(doc["room_key"])
          default = RoomModelDefault.find_or_initialize_by(account: @account, agent: agent, room_id: room_id(doc["room_key"]))
          default.model_id = doc["model_id"]
          default.save!
        end
        note!("progress", "room_model_defaults", true)
      end
    rescue ActiveRecord::RecordInvalid
      note!("progress", "room_model_defaults", "skipped")
    end

    def import_glossary
      return if ledger("progress").key?("glossary")
      TranscriptionGlossaryTerm.transaction do
        @archive.setup["glossary"].each do |doc|
          normalized = TranscriptionGlossaryTerm.normalize(doc["term"])
          next if @account.transcription_glossary_terms.exists?(normalized_term: normalized)
          @account.transcription_glossary_terms.create!(term: doc["term"], pinned: doc["pinned"], source: "manual", created_by_user_id: @user.id)
        end
        note!("progress", "glossary", true)
      end
    rescue ActiveRecord::RecordInvalid
      note!("progress", "glossary", "skipped")
    end

    def import_field
      tags = @archive.field["tags"].to_h { |t| [ t["key"], t["name"] ] }
      Archive::FIELD_KINDS.each do |kind|
        @archive.field[kind].each do |key|
          next if ledger("field").fetch(kind, {}).key?(key)
          doc = @archive.field_item(kind, key)
          blob = upload_media(doc["media"], @archive.field_media(kind, key))
          begin
            FieldFile.transaction do
              item = send(:"build_#{kind.singularize}", doc, blob)
              item.save!
              names = doc.fetch("tags", []).filter_map { |k| tags[k] }
              item.change_tags!(by: @user, set: names) if names.any? && item.respond_to?(:change_tags!)
              field_note!(kind, key, item.id)
            end
          rescue StandardError => error
            blob&.purge_later
            raise unless error.is_a?(ActiveRecord::RecordInvalid) || error.is_a?(FieldTag::Invalid)
            field_note!(kind, key, { "skipped" => error.message.to_s.truncate(500) })
          end
        end
      end
    end

    def field_note!(kind, key, value)
      @import.with_lock do
        ledger = @import.ledger.deep_dup
        ((ledger["field"] ||= {})[kind] ||= {})[key] = value
        @import.update_columns(ledger: ledger, updated_at: Time.current)
      end
    end

    # Uploaded before the item's transaction (ActiveStorage uploads cannot
    # roll back); purged if the item is not created.
    def upload_media(media, path)
      return nil unless media && path
      File.open(path, "rb") do |io|
        ActiveStorage::Blob.create_and_upload!(io: io, filename: media["filename"], content_type: media["content_type"].presence, identify: media["content_type"].blank?)
      end
    end

    def attribution(author)
      return nil unless author
      author["type"] == "resident" ? agent_for(author["key"]) : nil
    end

    def time(value) = value && Time.iso8601(value)

    def build_file(doc, blob)
      file = @account.field_files.new(title: doc["title"], note: doc["note"], dated_at: time(doc["dated_at"]) || time(doc["created_at"]),
        uploaded_by: attribution(doc["author"]) || @user, extracted_text: doc["extracted_text"],
        summary_short: doc["summary_short"], summary_long: doc["summary_long"], summarized_at: time(doc["summarized_at"]),
        summary_input_digest: doc["summary_input_digest"])
      file.file.attach(blob) if blob
      file
    end

    def build_recording(doc, blob)
      attributes = doc.slice(*Export::RECORDING_FIELDS)
      recording = @account.field_recordings.new(attributes.merge(
        title: doc["title"], uploaded_by: attribution(doc["author"]) || @user,
        recorded_at: time(doc["recorded_at"]) || time(doc["created_at"]), ready_at: time(doc["ready_at"]),
        summarized_at: time(doc["summarized_at"]), import_key: nil
      ))
      # A recording that had not finished arrives failed with its reason, so
      # a person chooses whether to spend allowance transcribing it again.
      unless recording.status.in?(%w[ready failed rejected])
        recording.status = "failed"
        recording.failure_reason = "Imported before transcription finished"
      end
      recording.audio.attach(blob) if blob
      recording
    end

    def build_song(doc, blob)
      song = @account.field_songs.new(doc.slice(*Export::SONG_FIELDS).merge(title: doc["title"], dated_at: time(doc["dated_at"]),
        added_by: attribution(doc["author"]) || @user))
      song.audio.attach(blob) if blob
      song
    end

    def build_note(doc, _blob)
      @account.whiteboards.new(name: doc["title"], content: doc["content"], summary: doc["summary"], dated_at: time(doc["dated_at"]),
        last_edited_by: attribution(doc["author"]) || @user, last_edited_at: Time.current)
    end

    def import_rhythms
      @archive.setup["rhythms"].each do |doc|
        key = doc["key"]
        next if ledger("rhythms").key?(key)
        agents = doc["resident_keys"].filter_map { |k| agent_for(k) }
        if agents.empty?
          skip!("rhythms", key, "None of its residents arrived")
          next
        end
        Rhythm.transaction do
          rhythm = Rhythm.new(doc.slice(*%w[title append_date opening cadence time_of_day weekday month_day month timezone room_choice]).merge(
            account: @account, creator: @user, agents: agents, room_id: room_id(doc["room_key"])))
          rhythm.room_choice = "resident_default" if rhythm.room_choice_room? && rhythm.room_id.nil?
          rhythm.save!
          rhythm.holds.create!(kind: "human", user: @user, reason: "Imported with an account archive; held until a person resumes it.")
          note!("rhythms", key, rhythm.id)
        end
      rescue ActiveRecord::RecordInvalid => error
        skip!("rhythms", key, error.record.errors.full_messages.to_sentence)
      end
    end

    def import_conversations
      @archive.conversation_keys.each do |key|
        next if ledger("conversations").key?(key)
        doc = @archive.conversation(key)
        agents = doc["resident_keys"].filter_map { |k| agent_for(k) }
        Chat.transaction do
          chat = @account.chats.new(title: doc["title"].presence || "Imported conversation", room_id: room_id(doc["room_key"]),
            archived_at: Time.current, manual_responses: agents.any?, agents: agents, created_at: time(doc["created_at"]))
          chat.save!
          rows = doc["messages"].map { |message| message_row(chat, message) }
          rows.each_slice(1000) { |slice| Message.insert_all!(slice) }
          chat.update_columns(last_message_at: rows.last&.dig(:created_at))
          note!("conversations", key, chat.id)
        end
      rescue ActiveRecord::RecordInvalid => error
        skip!("conversations", key, error.record.errors.full_messages.to_sentence)
      end
    end

    # Inserted without callbacks: an imported message never wakes anyone,
    # hands off, judges reflexes or replays a tool call.
    def message_row(chat, message)
      author = message["author"]
      agent = message["role"] == "assistant" ? attribution(author) : nil
      content = message["content"].to_s
      if agent.nil? && author
        name = author["type"] == "name" ? author["name"] : @archive.manifest["residents"].find { |r| r["key"] == author["key"] }&.dig("name")
        content = "**#{name}:** #{content}" if name.present?
      end
      at = time(message["created_at"])
      { chat_id: chat.id, role: message["role"], content: content, agent_id: agent&.id, user_id: nil,
        created_at: at, updated_at: at, tools_used: [] }
    end

    def summarise
      led = @import.reload.ledger
      count = ->(section) { led.fetch(section, {}).values.count { |v| !v.is_a?(Hash) || !v.key?("skipped") } }
      skipped = ->(section) { led.fetch(section, {}).filter_map { |k, v| { "key" => k, "reason" => v["skipped"] } if v.is_a?(Hash) && v["skipped"] } }
      field = led.fetch("field", {})
      {
        "residents" => led.fetch("residents", {}).count { |_, v| v.is_a?(Hash) && v["agent_id"] },
        "residents_skipped" => skipped.call("residents"),
        "field" => Archive::FIELD_KINDS.index_with { |kind| field.fetch(kind, {}).count { |_, v| v.is_a?(Integer) } },
        "field_skipped" => Archive::FIELD_KINDS.flat_map { |kind| field.fetch(kind, {}).filter_map { |k, v| { "kind" => kind, "key" => k, "reason" => v["skipped"] } if v.is_a?(Hash) } },
        "rooms" => count.call("rooms"),
        "rhythms" => count.call("rhythms"), "rhythms_skipped" => skipped.call("rhythms"),
        "conversations" => count.call("conversations"), "conversations_skipped" => skipped.call("conversations"),
        "services_to_reconnect" => @archive.setup["services"],
        "omitted_at_export" => @archive.manifest["omitted"]
      }
    end

  end
end

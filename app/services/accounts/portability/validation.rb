module Accounts::Portability
  # Shape checks for the archive's JSON documents, run before preview and
  # again before import. Model validations still run on create; this layer
  # makes sure every reference resolves inside the archive and every value is
  # the type the importer will read, so the preview cannot promise something
  # the import would then refuse halfway.
  class Validation

    def initialize(archive)
      @archive = archive
    end

    def call
      keys = @archive.manifest["residents"].map { |r| r["key"] }
      included = @archive.manifest["residents"].select { |r| r["status"] == "included" }.map { |r| r["key"] }
      omitted!(@archive.manifest["omitted"])
      included.each { |key| reflexes!(@archive.resident_extra(key)) }

      setup = @archive.setup
      hash!(setup, %w[rooms room_model_defaults rhythms glossary services])
      rooms = list!(setup["rooms"], 100)
      room_keys = rooms.map do |room|
        hash!(room, %w[key name])
        key!(room["key"])
        string!(room["name"], 40)
        string!(room["description"], 280, nil_ok: true)
        room["key"]
      end
      unique!(room_keys)
      list!(setup["room_model_defaults"], 1000).each do |d|
        hash!(d, %w[resident_key model_id])
        ref!(d["room_key"], room_keys, nil_ok: true)
        ref!(d["resident_key"], keys)
        string!(d["model_id"], 200)
      end
      unique!(list!(setup["rhythms"], 500).map do |rhythm|
        hash!(rhythm, %w[key title opening cadence time_of_day timezone room_choice resident_keys])
        key!(rhythm["key"])
        string!(rhythm["title"], 255)
        string!(rhythm["opening"], 20_000)
        raise Error, "Invalid rhythm" unless rhythm["cadence"].in?(%w[daily weekly monthly yearly]) && rhythm["room_choice"].in?(Rhythm::ROOM_CHOICES)
        string!(rhythm["time_of_day"], 5)
        string!(rhythm["timezone"], 100)
        %w[weekday month_day month].each { |f| raise Error, "Invalid rhythm" unless rhythm[f].nil? || rhythm[f].is_a?(Integer) }
        raise Error, "Invalid rhythm" unless [ true, false ].include?(rhythm["append_date"])
        ref!(rhythm["room_key"], room_keys, nil_ok: true)
        list!(rhythm["resident_keys"], 100).each { |k| ref!(k, keys) }
        rhythm["key"]
      end)
      list!(setup["glossary"], 5_000).each do |term|
        hash!(term, %w[term pinned])
        string!(term["term"], 200)
        raise Error, "Invalid glossary term" unless [ true, false ].include?(term["pinned"])
      end
      list!(setup["services"], 500).each do |service|
        hash!(service, %w[provider])
        string!(service["provider"], 100)
        string!(service["label"], 200, nil_ok: true)
        string!(service["kind"], 100, nil_ok: true)
      end

      field = @archive.field
      hash!(field, Archive::FIELD_KINDS + %w[tags])
      tag_keys = list!(field["tags"], 10_000).map do |tag|
        hash!(tag, %w[key name])
        key!(tag["key"])
        string!(tag["name"], FieldTag::MAX_NAME_LENGTH)
        tag["key"]
      end
      unique!(tag_keys)
      Archive::FIELD_KINDS.each do |kind|
        unique!(list!(field[kind], Archive::MAX_ENTRIES).each do |key|
          key!(key)
          item!(kind, @archive.field_item(kind, key), keys, tag_keys)
          media = @archive.field_item(kind, key)["media"]
          member = "field/#{kind}/#{key}/media"
          if media
            raise Error, "Field media does not match its record" unless @archive.entries.key?(member) &&
              @archive.entries[member]["sha256"] == media["sha256"] && @archive.entries[member]["size"] == media["byte_size"]
          elsif @archive.entries.key?(member)
            raise Error, "Unexpected Field media"
          end
        end)
      end
      orphan = @archive.entries.keys.find do |name|
        next unless (match = name.match(%r{\Afield/([a-z]+)/([a-z0-9]+)/}))
        !field[match[1]].include?(match[2])
      end
      raise Error, "Field member outside the index" if orphan

      conversation_keys = @archive.conversation_keys
      if @archive.manifest.dig("options", "conversations")
        unique!(list!(conversation_keys, Archive::MAX_ENTRIES).each { |key| key!(key) })
        conversation_keys.each { |key| conversation!(@archive.conversation(key), keys, room_keys) }
        raise Error, "Invalid conversation key" if conversation_keys.include?("index")
        stray = @archive.entries.keys.find do |n|
          n != "conversations/index.json" && n.match?(%r{\Aconversations/[a-z0-9]+\.json\z}) && !conversation_keys.include?(n[%r{conversations/([a-z0-9]+)\.json}, 1])
        end
        raise Error, "Conversation outside the index" if stray
      end
    end

    private

    def omitted!(list)
      list!(list, Archive::MAX_ENTRIES).each do |item|
        hash!(item, %w[kind title reason])
        %w[kind title reason].each { |k| string!(item[k], 500) }
      end
    end

    def reflexes!(doc)
      hash!(doc, %w[reflexes])
      list!(doc["reflexes"], Reflex::MAX_KEPT).each do |reflex|
        hash!(reflex, %w[name shape reminder])
        string!(reflex["name"], Reflex::NAME_LENGTH)
        string!(reflex["shape"], Reflex::SHAPE_LENGTH)
        string!(reflex["reminder"], Reflex::REMINDER_LENGTH)
      end
    end

    def item!(kind, doc, resident_keys, tag_keys)
      hash!(doc, %w[title])
      string!(doc["title"], 200)
      %w[created_at dated_at recorded_at ready_at summarized_at].each { |f| time!(doc[f]) if doc.key?(f) }
      author!(doc["author"], resident_keys)
      list!(doc["tags"] || [], 200).each { |k| ref!(k, tag_keys) }
      media = doc["media"]
      unless media.nil?
        hash!(media, %w[filename content_type byte_size sha256])
        string!(media["filename"], 255)
        string!(media["content_type"], 255, nil_ok: true)
        raise Error, "Invalid media record" unless media["byte_size"].is_a?(Integer) && media["sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
      end
      case kind
      when "recordings"
        raise Error, "Invalid recording status" unless doc["status"].in?(FieldRecording::STATUSES)
        raise Error, "Invalid recording transcript" unless doc["transcript_turns"].nil? || doc["transcript_turns"].is_a?(Array)
        raise Error, "Invalid recording transcript" unless doc["transcript_words"].nil? || doc["transcript_words"].is_a?(Array)
      when "songs"
        raise Error, "Invalid song links" unless doc["links"].nil? || doc["links"].is_a?(Array)
      end
    end

    def conversation!(doc, resident_keys, room_keys)
      hash!(doc, %w[title created_at resident_keys messages])
      string!(doc["title"], 200, nil_ok: true)
      time!(doc["created_at"])
      ref!(doc["room_key"], room_keys, nil_ok: true)
      list!(doc["resident_keys"], 100).each { |k| ref!(k, resident_keys) }
      list!(doc["messages"], 100_000).each do |message|
        hash!(message, %w[role content created_at])
        raise Error, "Invalid message role" unless message["role"].in?(Export::MESSAGE_ROLES)
        string!(message["content"], 1_000_000, blank_ok: true)
        time!(message["created_at"])
        author!(message["author"], resident_keys)
      end
    end

    def author!(author, resident_keys)
      return if author.nil?
      hash!(author, %w[type])
      case author["type"]
      when "resident" then ref!(author["key"], resident_keys)
      when "name" then string!(author["name"], 200)
      else raise Error, "Invalid author"
      end
    end

    def hash!(value, required)
      raise Error, "Invalid archive document" unless value.is_a?(Hash) && required.all? { |k| value.key?(k) }
      value
    end

    def list!(value, max)
      raise Error, "Invalid archive list" unless value.is_a?(Array) && value.length <= max
      value
    end

    def string!(value, max, nil_ok: false, blank_ok: false)
      return if nil_ok && value.nil?
      raise Error, "Invalid archive text" unless value.is_a?(String) && value.length <= max && (blank_ok || nil_ok || value.present?)
    end

    def key!(value)
      raise Error, "Invalid archive key" unless value.is_a?(String) && value.match?(Archive::KEY)
    end

    def ref!(value, keys, nil_ok: false)
      return if nil_ok && value.nil?
      raise Error, "Archive reference does not resolve" unless keys.include?(value)
    end

    def unique!(keys)
      raise Error, "Duplicate archive key" unless keys.uniq.length == keys.length
    end

    def time!(value)
      return if value.nil?
      raise Error, "Invalid archive timestamp" unless value.is_a?(String) && value.length <= 40
      Time.iso8601(value)
    end

  end
end

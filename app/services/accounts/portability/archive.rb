require "zip"
require "digest"
require "tmpdir"
require "set"

module Accounts::Portability
  # The outer account archive: a ZIP. Its limits are its own, not the
  # resident archive's; each nested resident tar.gz is still validated by
  # Agents::Portability::Archive when it is imported. Every upload is hostile:
  # all bounds apply while extracting into a private staging directory, before
  # anything persistent is created.
  class Archive

    FORMAT = "souls-account/v1"
    # Explicit, and shown on the export and import pages. A recording may be
    # 2 GB (FieldRecording upload cap), so that is the per-entry bound.
    MAX_COMPRESSED = 16.gigabytes
    MAX_EXPANDED = 16.gigabytes
    MAX_ENTRIES = 50_000
    MAX_ENTRY = 2.gigabytes
    MAX_JSON = 32.megabytes
    KEY = /\A[a-z0-9]{1,40}\z/
    FIELD_KINDS = %w[files recordings songs notes].freeze
    MEMBER = %r{\A(?:field/(?:#{FIELD_KINDS.join("|")})/[a-z0-9]{1,40}/(?:item\.json|media)|conversations/[a-z0-9]{1,40}\.json)\z}
    MAX_PATH_BYTES = 240

    WARNINGS = [
      "This is a copy. Nothing in the source account is moved, stopped or deleted.",
      "Credentials, service connections, API keys, billing, members and invitations do not travel. Reconnect services by hand.",
      "Residents that were running when the export was made are not in it; their entries say why. Such an archive is a partial export.",
      "Imported residents arrive stopped, and imported rhythms arrive held. Nothing runs until a person starts it.",
      "Checksums detect corruption; they do not prove who made the archive.",
      "Confidential plaintext: compression is not encryption."
    ].freeze

    CONVERSATIONS_WARNING = "Conversations are included: other people's messages, and anything written in chat, travel with this archive. " \
      "Message text only; attachments, tool calls and runtime state do not travel.".freeze

    # Opens an upload (an IO), extracts it under the bounds and yields the
    # validated archive. The staging directory is removed afterwards.
    def self.with_file(io)
      raise Error, "An archive file is required" unless io.respond_to?(:read)
      Dir.mktmpdir("account-import-") do |dir|
        File.chmod(0700, dir)
        compressed = File.join(dir, "upload.zip")
        digest = Digest::SHA256.new
        io.rewind if io.respond_to?(:rewind)
        File.open(compressed, "wb", 0600) do |out|
          count = 0
          while (chunk = io.read(1.megabyte))
            count += chunk.bytesize
            raise Error, "Archive exceeds the account archive's compressed limit" if count > MAX_COMPRESSED
            digest.update(chunk)
            out.write(chunk)
          end
        end
        stage = File.join(dir, "stage")
        Dir.mkdir(stage, 0700)
        entries = extract(compressed, stage)
        archive = new(stage, entries, digest.hexdigest)
        archive.validate!
        yield archive
      end
    rescue Zip::Error, JSON::ParserError, ArgumentError, TypeError, KeyError, EOFError, RangeError
      raise Error, "Invalid account archive"
    end

    def self.limits
      { compressed: MAX_COMPRESSED, expanded: MAX_EXPANDED, entries: MAX_ENTRIES, entry: MAX_ENTRY }
    end

    def self.safe_path!(name)
      raise Error, "Unsafe archive path" unless name.is_a?(String) && name.bytesize <= MAX_PATH_BYTES &&
        name.dup.force_encoding(Encoding::UTF_8).valid_encoding? && !name.match?(/[\x00-\x1f\x7f\\:]/)
      parts = name.split("/", -1)
      raise Error, "Unsafe archive path" if name.start_with?("/") || parts.empty? || parts.any? { |p| p.empty? || p == "." || p == ".." }
      name
    end

    UNIX_TYPE_MASK = 0o170000
    UNIX_REGULAR = 0o100000
    # Every member name the format can contain. Checked on the raw central
    # directory before rubyzip reads it (rubyzip keys entries by name, so
    # duplicates collapse before any count) and before anything is written,
    # so an unknown path never creates a directory.
    LAYOUT = %r{\A(?:manifest\.json|README\.md|setup\.json|field/index\.json|conversations/index\.json|
      residents/[a-z0-9]{1,40}\.(?:tar\.gz|json)|field/(?:#{FIELD_KINDS.join("|")})/[a-z0-9]{1,40}/(?:item\.json|media)|
      conversations/[a-z0-9]{1,40}\.json)\z}x
    EOCD = "PK\x05\x06".b
    ZIP64_EOCD = "PK\x06\x06".b
    ZIP64_LOCATOR = "PK\x06\x07".b
    CENTRAL = "PK\x01\x02".b

    # Reads the raw central directory: the real number of records and their
    # names, refusing duplicates (case-folded), unknown layout, too many
    # records and trailing bytes. Handles ZIP64 end records.
    def self.prescan!(zip_path)
      File.open(zip_path, "rb") do |io|
        size = io.size
        raise Error, "Invalid account archive" if size < 22
        tail_length = [ size, 22 + 65_535 ].min
        io.seek(size - tail_length)
        tail = io.read(tail_length)
        at = tail.rindex(EOCD) or raise Error, "Invalid account archive"
        record = tail.byteslice(at, 22)
        raise Error, "Invalid account archive" unless record&.bytesize == 22
        disk, cd_disk, on_disk, total, cd_size, cd_offset, comment = record.unpack("x4vvvvVVv")
        raise Error, "Trailing archive data is forbidden" unless at + 22 + comment == tail_length
        raise Error, "Multi-part archives are not supported" unless disk.zero? && cd_disk.zero? && on_disk == total
        if total == 0xFFFF || cd_size == 0xFFFF_FFFF || cd_offset == 0xFFFF_FFFF
          locator_at = size - tail_length + at - 20
          raise Error, "Invalid account archive" if locator_at.negative?
          io.seek(locator_at)
          locator = io.read(20)
          raise Error, "Invalid account archive" unless locator&.byteslice(0, 4) == ZIP64_LOCATOR
          z64_offset = locator.byteslice(8, 8).unpack1("Q<")
          raise Error, "Invalid account archive" unless z64_offset + 56 <= locator_at
          io.seek(z64_offset)
          z64 = io.read(56)
          raise Error, "Invalid account archive" unless z64&.bytesize == 56 && z64.byteslice(0, 4) == ZIP64_EOCD
          on_disk, total, cd_size, cd_offset = z64.byteslice(24, 32).unpack("Q<Q<Q<Q<")
          raise Error, "Multi-part archives are not supported" unless on_disk == total
        end
        raise Error, "Too many archive entries" if total > MAX_ENTRIES
        raise Error, "Invalid account archive" if cd_offset + cd_size > size
        # Walked record by record from the file: only one fixed header and
        # one name are ever in memory, whatever the directory claims.
        names = []
        folded = Set.new
        position = cd_offset
        finish = cd_offset + cd_size
        while position < finish
          raise Error, "Too many archive entries" if names.length >= MAX_ENTRIES
          io.seek(position)
          header = io.read(46)
          raise Error, "Invalid account archive" unless header&.bytesize == 46 && header.byteslice(0, 4) == CENTRAL
          name_length, extra_length, comment_length = header.byteslice(28, 6).unpack("vvv")
          raise Error, "Unsafe archive path" if name_length > MAX_PATH_BYTES
          name = io.read(name_length).to_s
          raise Error, "Invalid account archive" unless name.bytesize == name_length
          name.force_encoding(Encoding::UTF_8)
          raise Error, "Unsafe archive path" unless name.valid_encoding?
          raise Error, "Unsupported archive member" unless name.match?(LAYOUT)
          raise Error, "Duplicate archive entry" unless folded.add?(name.downcase)
          names << name
          position += 46 + name_length + extra_length + comment_length
        end
        raise Error, "Invalid account archive" unless position == finish
        raise Error, "Invalid account archive" unless names.length == total
        names
      end
    end

    def self.extract(zip_path, stage)
      names = prescan!(zip_path)
      entries = {}
      expanded = 0
      Zip::File.open(zip_path) do |zip|
        # rubyzip collapses same-name records; the raw count must survive it.
        raise Error, "Duplicate archive entry" unless zip.size == names.length
        zip.each do |entry|
          name = entry.name.dup.force_encoding(Encoding::UTF_8)
          safe_path!(name)
          raise Error, "Unsupported archive member" unless name.match?(LAYOUT) && names.include?(name)
          raise Error, "Encrypted archive entries are not supported" if entry.encrypted?
          unix_type = (entry.external_file_attributes.to_i >> 16) & UNIX_TYPE_MASK
          raise Error, "Links and special archive entries are forbidden" if entry.symlink? || !(unix_type.zero? || unix_type == UNIX_REGULAR)
          raise Error, "Archive member exceeds the per-entry limit" if entry.size.to_i > MAX_ENTRY || entry.size.to_i.negative?
          target = File.join(stage, name)
          FileUtils.mkdir_p(File.dirname(target), mode: 0700)
          raise Error, "Conflicting archive path" if File.exist?(target)
          digest = Digest::SHA256.new
          size = 0
          File.open(target, "wb", 0600) do |out|
            entry.get_input_stream do |input|
              while (chunk = input.read(1.megabyte)) && !chunk.empty?
                size += chunk.bytesize
                expanded += chunk.bytesize
                raise Error, "Archive member exceeds the per-entry limit" if size > MAX_ENTRY
                raise Error, "Archive exceeds the account archive's expanded limit" if expanded > MAX_EXPANDED
                out.write(chunk)
                digest.update(chunk)
              end
            end
          end
          entries[name] = { "size" => size, "sha256" => digest.hexdigest }
        end
      end
      entries
    rescue Errno::EEXIST, Errno::ENOTDIR, Errno::EISDIR
      raise Error, "Conflicting archive path"
    end

    # Writes stage/<path> for every inventoried path into a new ZIP.
    def self.pack(stage, entries, output)
      Zip::File.open(output, create: true) do |zip|
        entries.each_key do |path|
          zip.add(path, File.join(stage, path))
        end
      end
      File.chmod(0600, output)
      raise Error, "Account archive exceeds its compressed limit" if File.size(output) > MAX_COMPRESSED
    end

    attr_reader :stage, :entries, :sha256, :manifest

    def initialize(stage, entries, sha256)
      @stage, @entries, @sha256 = stage, entries, sha256
    end

    def path(name)
      raise Error, "Missing archive member" unless entries.key?(name)
      File.join(stage, name)
    end

    def json(name)
      raise Error, "Missing archive document" unless entries.key?(name)
      raise Error, "Archive document exceeds its limit" if entries[name]["size"] > MAX_JSON
      JSON.parse(File.read(path(name)))
    end

    def validate!
      @manifest = json("manifest.json")
      raise Error, "Invalid archive manifest" unless manifest.is_a?(Hash)
      raise Error, "Unsupported account archive version" unless manifest["format"] == FORMAT
      raise Error, "Invalid archive inventory" unless manifest["inventory"] == entries.except("manifest.json")
      raise Error, "Missing documentation" unless entries.key?("README.md")
      uuid = /\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/
      raise Error, "Invalid export identity" unless manifest["export_id"].is_a?(String) && manifest["export_id"].match?(uuid)
      raise Error, "Invalid provenance" unless manifest["source_installation"].is_a?(String) && manifest["source_installation"].match?(/\A[0-9a-f]{64}\z/)
      Time.iso8601(manifest["created_at"].to_s)
      raise Error, "Invalid options" unless manifest["options"].is_a?(Hash) && [ true, false ].include?(manifest.dig("options", "conversations"))
      raise Error, "Conversations present without the option" if !manifest.dig("options", "conversations") && entries.keys.any? { |n| n.start_with?("conversations/") }

      residents = manifest["residents"]
      raise Error, "Invalid resident list" unless residents.is_a?(Array) && residents.length <= 500
      keys = residents.map { |r| r.is_a?(Hash) ? r["key"] : nil }
      raise Error, "Invalid resident keys" unless keys.all? { |k| k.is_a?(String) && k.match?(/\A[a-z0-9]{1,40}\z/) } && keys.uniq.length == keys.length
      residents.each do |resident|
        raise Error, "Invalid resident entry" unless resident["name"].is_a?(String) && resident["name"].length.between?(1, 200) && resident["status"].in?(%w[included skipped])
        if resident["status"] == "included"
          raise Error, "Missing resident archive" unless resident["archive"] == "residents/#{resident["key"]}.tar.gz" && entries.key?(resident["archive"])
        else
          raise Error, "Skipped resident needs a reason" unless resident["reason"].is_a?(String) && resident["reason"].present?
          raise Error, "Skipped resident has an archive" if entries.key?("residents/#{resident["key"]}.tar.gz")
        end
      end

      allowed = %w[manifest.json README.md setup.json field/index.json conversations/index.json]
      entries.each_key do |name|
        next if allowed.include?(name)
        next if keys.any? { |k| name == "residents/#{k}.tar.gz" || name == "residents/#{k}.json" }
        next if name.match?(MEMBER)
        raise Error, "Unsupported archive member"
      end

      Validation.new(self).call
      true
    end

    def setup = @setup ||= json("setup.json")
    def field = @field ||= json("field/index.json")
    def conversation_keys = manifest.dig("options", "conversations") ? (@conversation_keys ||= json("conversations/index.json")) : []
    def conversation(key) = json("conversations/#{key}.json")
    def field_item(kind, key) = json("field/#{kind}/#{key}/item.json")
    def field_media(kind, key) = entries.key?("field/#{kind}/#{key}/media") ? path("field/#{kind}/#{key}/media") : nil
    def resident_extra(key) = entries.key?("residents/#{key}.json") ? json("residents/#{key}.json") : {}

    # Each included resident's own archive, checked with the resident
    # archive's boundary before any preview, so the preview says which
    # residents will really arrive. key => nil (valid) or the reason.
    def resident_checks
      @resident_checks ||= manifest["residents"].select { |r| r["status"] == "included" }.to_h do |resident|
        reason = begin
          File.open(path(resident["archive"]), "rb") { |file| Agents::Portability::Archive.with_upload(file) { |_inner| } }
          nil
        rescue Agents::Portability::Error, Agents::Resources::OwnershipError => error
          error.message.presence || "Invalid resident archive"
        end
        [ resident["key"], reason ]
      end
    end

    def preview
      setup_doc = setup
      field_doc = field
      {
        export_id: manifest["export_id"],
        created_at: manifest["created_at"],
        account_name: manifest["account_name"],
        partial: manifest["partial"] == true,
        sha256: sha256,
        residents: manifest["residents"].map do |r|
          if r["status"] == "included" && (reason = resident_checks[r["key"]])
            r.slice("key", "name").merge("status" => "invalid", "reason" => "Its resident archive is not valid: #{reason}")
          else
            r.slice("key", "name", "status", "reason")
          end
        end,
        field: FIELD_KINDS.index_with { |kind| field_doc[kind].length }.merge("tags" => field_doc["tags"].length),
        rooms: setup_doc["rooms"].map { |room| room["name"] },
        rhythms: setup_doc["rhythms"].length,
        glossary_terms: setup_doc["glossary"].length,
        services: setup_doc["services"],
        conversations: conversation_keys.length,
        limits: self.class.limits,
        omitted: manifest["omitted"],
        warnings: manifest["warnings"]
      }
    end

  end
end

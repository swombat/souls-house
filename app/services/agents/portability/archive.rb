require "rubygems/package"
require "zlib"
require "digest"
require "tmpdir"
require "set"

module Agents::Portability
  # Deliberately small synchronous v1. All limits apply before persistent writes.
  class Archive

    FORMAT = "souls-resident/v1"
    MAX_COMPRESSED = 100.megabytes
    MAX_EXPANDED = 512.megabytes
    MAX_ENTRIES = 20_000
    MAX_FILE = 64.megabytes
    MAX_JSON = 8.megabytes
    MAX_GRAPH = Mnemodyne::Checkpoint::MAX_BYTES
    ROOTS = %w[identity repo work].freeze
    WARNINGS = [
      "This is a separate copy. The source is preserved and can resume later.",
      "Conversations and session history are excluded for multi-party privacy; restored sessions start fresh.",
      "Credentials, service access, integrations and schedules are not inherited. Reconnect deliberately.",
      "Checksums detect corruption, not authenticate the archive producer.",
      "Confidential plaintext archive: authored files may contain private data. Compression is not encryption."
    ].freeze
    METADATA = %w[name model_id reasoning_effort colour icon persistent_session persistent_wake_session scheduled_wakes_enabled heartbeat_wakes_per_day session_idle_timeout_minutes session_max_age_minutes session_context_budget_tokens turn_timeout_minutes].freeze
    LEGACY_FIELDS = %w[content memory_type constitutional created_at updated_at discarded_at].freeze

    def self.with_upload(upload)
      raise Error, "An archive file is required" unless upload.respond_to?(:read)
      Dir.mktmpdir("resident-import-") do |dir|
        File.chmod(0700, dir)
        compressed = File.join(dir, "upload.gz")
        upload.rewind
        File.open(compressed, "wb", 0600) do |out|
          count = 0
          while (chunk = upload.read(64.kilobytes))
            count += chunk.bytesize
            raise Error, "Archive exceeds v1 compressed limit" if count > MAX_COMPRESSED
            out.write(chunk)
          end
        end
        expanded = File.join(dir, "archive.tar")
        Zlib::GzipReader.open(compressed) do |gz|
          File.open(expanded, "wb", 0600) do |out|
            count = 0
            until gz.eof?
              chunk = gz.read(64.kilobytes)
              count += chunk.bytesize
              raise Error, "Archive exceeds v1 expanded limit" if count > MAX_EXPANDED
              out.write(chunk)
            end
          end
          raise Error, "Trailing compressed data is forbidden" if gz.unused.to_s.present? || gz.finish.read(1).present?
        end
        stage = File.join(dir, "stage")
        Dir.mkdir(stage, 0700)
        entries = unpack(expanded, stage)
        archive = new(stage, entries)
        archive.validate!
        yield archive
      end
    rescue Zlib::Error, Gem::Package::TarInvalidError, JSON::ParserError, EOFError, ArgumentError, TypeError, KeyError
      raise Error, "Invalid resident archive"
    end

    def self.safe_path!(name)
      raise Error, "Unsafe archive path" unless name.is_a?(String) && name.bytesize <= 240 && name.dup.force_encoding(Encoding::UTF_8).valid_encoding? && !name.match?(/[\x00-\x1f\x7f\\]/)
      parts = name.split("/", -1)
      raise Error, "Unsafe archive path" if parts.empty? || parts.any? { |p| p.empty? || p == "." || p == ".." } || name.start_with?("/")
      name
    end

    def self.unpack(tar_path, stage, prefix: nil)
      validate_tar!(tar_path)
      entries = {}
      filesystem_paths = Set.new
      File.open(tar_path, "rb") do |io|
        Gem::Package::TarReader.new(io) do |tar|
          tar.each do |entry|
            name = entry.full_name
            if prefix
              next if [ ".", "./" ].include?(name) && entry.directory?
              name = name.delete_prefix("./").delete_suffix("/")
              name = "#{prefix}/#{name}"
            end
            name = name.dup.force_encoding(Encoding::UTF_8)
            safe_path!(name)
            pieces = name.split("/")
            pieces.length.times { |i| filesystem_paths.add(pieces.first(i + 1).join("/")) }
            raise Error, "Too many archive paths including implicit directories" if filesystem_paths.length > MAX_ENTRIES
            raise Error, "Duplicate archive entry" if entries.key?(name)
            raise Error, "Too many archive entries" if entries.length >= MAX_ENTRIES
            raise Error, "Links and special archive entries are forbidden" unless entry.header.typeflag.in?([ "0", "", "5" ])
            raise Error, "Archive member exceeds v1 limit" if entry.header.size > MAX_FILE || entry.header.size.negative?
            raise Error, "Invalid directory" if entry.directory? && entry.header.size != 0
            mode = entry.header.mode & 0777
            # Never preserve setuid/setgid/sticky or group/world write access.
            mode &= ~0022
            target = File.join(stage, name)
            FileUtils.mkdir_p(File.dirname(target), mode: 0700)
            raise Error, "Conflicting archive path" if File.exist?(target) && !(entry.directory? && File.directory?(target))
            if entry.directory?
              Dir.mkdir(target, 0700) unless File.directory?(target)
              digest = nil
            else
              digest = Digest::SHA256.new
              File.open(target, "wb", 0600) do |out|
                while (chunk = entry.read(64.kilobytes)) && !chunk.empty?
                  out.write(chunk)
                  digest.update(chunk)
                end
              end
              digest = digest.hexdigest
            end
            entries[name] = { "type" => entry.directory? ? "directory" : "file", "size" => entry.header.size, "mode" => mode, "sha256" => digest }
          end
        end
        # TarReader stops at the first zero block; reject hidden second archives.
        while (chunk = io.read(64.kilobytes))
          raise Error, "Trailing tar data is forbidden" unless chunk.bytes.all?(&:zero?)
        end
      end
      entries
    rescue Errno::EEXIST, Errno::ENOTDIR
      raise Error, "Conflicting archive path"
    end

    def self.validate_tar!(path)
      raise Error, "Archive exceeds v1 expanded limit" if File.size(path) > MAX_EXPANDED
      File.open(path, "rb") do |io|
        count = 0
        loop do
          header = io.read(512)
          raise Error, "Truncated tar archive" unless header && header.bytesize == 512
          if header.bytes.all?(&:zero?)
            second = io.read(512)
            raise Error, "Invalid tar terminator" unless second && second.bytesize == 512 && second.bytes.all?(&:zero?)
            while (tail = io.read(64.kilobytes))
              raise Error, "Trailing tar data is forbidden" unless tail.bytes.all?(&:zero?)
            end
            break
          end
          count += 1
          raise Error, "Too many archive entries" if count > MAX_ENTRIES
          checksum = header.byteslice(148, 8)
          size = header.byteslice(124, 12)
          raise Error, "Invalid tar header" unless checksum.match?(/\A[0-7]+[\x00 ]*\z/) && size.match?(/\A[0-7]+[\x00 ]*\z/)
          expected = checksum.to_i(8)
          actual = header.bytes.sum - checksum.bytes.sum + 8 * 32
          raise Error, "Invalid tar header checksum" unless expected == actual
          bytes = size.to_i(8)
          raise Error, "Archive member exceeds v1 limit" if bytes > MAX_FILE
          padded = ((bytes + 511) / 512) * 512
          raise Error, "Truncated tar archive" if io.pos + padded > io.size
          io.seek(padded, IO::SEEK_CUR)
        end
      end
    end

    attr_reader :stage, :entries, :manifest
    def initialize(stage, entries)
      @stage, @entries = stage, entries
    end

    def json(path)
      raise Error, "Missing archive document" unless entries.dig(path, "type") == "file" && entries.dig(path, "size") <= (path == "memory/checkpoint.json" ? MAX_GRAPH : MAX_JSON)
      JSON.parse(File.read(File.join(stage, path)))
    end

    def validate!
      @manifest = json("manifest.json")
      raise Error, "Invalid archive manifest" unless manifest.is_a?(Hash)
      raise Error, "Unsupported archive version or graph backend" unless manifest["format"] == FORMAT && manifest["memory_backend"].in?(%w[native absent]) && manifest["home_profile"] == "house"
      raise Error, "Invalid archive inventory" unless manifest["inventory"] == entries.except("manifest.json")
      raise Error, "Invalid export identity" unless manifest["export_id"].is_a?(String) && manifest["export_id"].match?(/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/) && manifest["source_resident_id"].is_a?(String) && manifest["source_resident_id"].match?(/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/)
      raise Error, "Invalid metadata" unless manifest["metadata"].is_a?(Hash) && (manifest["metadata"].keys - METADATA).empty?
      raise Error, "Invalid provenance" unless manifest["source_installation"].is_a?(String) && manifest["source_installation"].match?(/\A[0-9a-f]{64}\z/) && manifest["exported_by"].is_a?(String) && manifest["exported_by"].match?(/\A[a-zA-Z0-9_-]{1,100}\z/)
      timestamp = manifest["created_at"]
      raise Error, "Invalid provenance timestamp" unless timestamp.is_a?(String) && timestamp.length <= 40 && timestamp.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/)
      Time.iso8601(timestamp)
      raise Error, "Unsupported root contract" unless manifest["included_roots"] == ROOTS && manifest["excluded_roots"] == %w[chaos state conversations]
      metadata = manifest["metadata"]
      strings = %w[name model_id reasoning_effort colour icon]
      booleans = %w[persistent_session persistent_wake_session scheduled_wakes_enabled]
      integers = METADATA - strings - booleans
      raise Error, "Invalid metadata types" unless strings.all? { |key| metadata[key].nil? || (metadata[key].is_a?(String) && metadata[key].bytesize <= 200) } && booleans.all? { |key| [ true, false ].include?(metadata[key]) } && integers.all? { |key| metadata[key].is_a?(Integer) }
      raise Error, "Invalid resident metadata" unless metadata["name"].present? && metadata["model_id"].present?
      candidate = Agent.new(metadata.merge("account" => Account.new, "runtime" => "offline"))
      raise Error, "Invalid resident metadata" unless candidate.valid?
      raise Error, "Missing documentation" unless entries.dig("README.md", "type") == "file"
      entries.each_key do |path|
        next if %w[manifest.json README.md memory/checkpoint.json memory/legacy.json].include?(path)
        raise Error, "Unsupported archive root" unless ROOTS.any? { |root| path == "resident/#{root}" || path.start_with?("resident/#{root}/") }
      end
      ROOTS.each { |root| raise Error, "Missing resident root" unless entries.dig("resident/#{root}", "type") == "directory" }
      raise Error, "Missing resident soul" unless entries.dig("resident/identity/soul.md", "type") == "file"
      raise Error, "Unexpected graph payload" if manifest["memory_backend"] == "absent" && entries.key?("memory/checkpoint.json")
      GraphImport.validate!(graph, manifest["source_resident_id"]) if manifest["memory_backend"] == "native"
      memories = legacy
      raise Error, "Invalid legacy memory payload" unless memories.is_a?(Array) && memories.length <= 1000 && memories.all? { |m| m.is_a?(Hash) && (m.keys - LEGACY_FIELDS).empty? && AgentMemory.new(m.merge("agent" => Agent.new)).valid? }
      true
    end

    def graph = manifest["memory_backend"] == "native" ? json("memory/checkpoint.json") : nil
    def legacy = json("memory/legacy.json")

    def preview(account)
      { name: manifest.dig("metadata", "name"), export_id: manifest["export_id"], source_resident_id: manifest["source_resident_id"], created_at: manifest["created_at"], files_count: entries.count { |_, v| v["type"] == "file" }, graph_nodes: graph&.dig("payload", "nodes")&.length || 0, graph_edges: graph&.dig("payload", "edges")&.length || 0, warnings: WARNINGS, duplicate: account.agents.where("portability_custody ->> 'export_id' = ?", manifest["export_id"]).exists? }
    end

    def self.pack(stage, entries, output)
      Zlib::GzipWriter.open(output) do |gz|
        Gem::Package::TarWriter.new(gz) do |tar|
          entries.each do |path, item|
            if item["type"] == "directory"
              tar.mkdir(path, item["mode"])
            else
              tar.add_file_simple(path, item["mode"], item["size"]) { |out| File.open(File.join(stage, path), "rb") { |input| IO.copy_stream(input, out) } }
            end
          end
        end
      end
      File.chmod(0600, output)
      raise Error, "Archive exceeds v1 compressed limit" if File.size(output) > MAX_COMPRESSED
    end

  end
end

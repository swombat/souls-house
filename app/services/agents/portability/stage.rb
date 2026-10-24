require "zlib"
require "digest"

module Agents::Portability
  # Persists a validated archive's three role homes for a later VM seed
  # (docs/2026-10-10-vm-imports.md, point 10). Archive.with_upload stages in a
  # temporary directory that is gone when the request ends; this keeps what a
  # VM needs past the request and past a process restart.
  #
  # Each role is capped at the runner's seed limit, so a stage that exists can
  # always be seeded. Nothing here buys, starts or restores anything.
  class Stage

    MAX_ROLE_BYTES = Agents::VmSeed::MAX_BYTES
    # Match SEED_MAX_UNPACKED and SEED_MAX_ENTRIES in
    # host-runner/souls_house_runner.py: a role the runner would refuse to
    # unpack is refused here, at import, not at Activate.
    MAX_ROLE_UNPACKED = 256.megabytes
    MAX_ROLE_ENTRIES = 20_000

    def self.max_role_bytes = MAX_ROLE_BYTES
    def self.max_role_unpacked = MAX_ROLE_UNPACKED
    def self.max_role_entries = MAX_ROLE_ENTRIES

    # Call inside the import's transaction, so a refused or failed import
    # leaves no stage behind. Refuses rather than replaces an existing stage.
    def self.persist!(archive, agent)
      raise Error, "This resident already has a staged home" if agent.import_stages.exists?

      Archive::ROOTS.each { |role| check_unpacked!(archive, role) }
      Archive::ROOTS.map do |role|
        bytes = gzip_role(archive, role)
        agent.import_stages.create!(role:, archive: bytes, sha256: Digest::SHA256.hexdigest(bytes), bytes: bytes.bytesize)
      end
    end

    def self.check_unpacked!(archive, role)
      members = archive.entries.select { |path, _| path.start_with?("resident/#{role}/") }
      raise Error, "The #{role} home has more files than a resident server can be seeded with (#{max_role_entries})" if members.length > max_role_entries

      unpacked = members.sum { |_, item| item["type"] == "file" ? item["size"] : 0 }
      raise Error, "The #{role} home is larger than a resident server can be seeded with (#{max_role_unpacked / 1.megabyte} MB unpacked)" if unpacked > max_role_unpacked
    end

    # Built in a private file inside the archive's stage, and read into memory
    # only once it is known to fit.
    def self.gzip_role(archive, role)
      path = File.join(archive.stage, "seed-#{role}.tar.gz")
      File.open(path, "wb", 0600) do |file|
        gz = Zlib::GzipWriter.new(file)
        archive.write_role_tar(role, gz)
        gz.finish
      end
      raise Error, "The #{role} home is larger than a resident server can be seeded with (#{max_role_bytes / 1.megabyte} MB compressed)" if File.size(path) > max_role_bytes

      File.binread(path)
    ensure
      File.delete(path) if path && File.exist?(path)
    end

  end
end

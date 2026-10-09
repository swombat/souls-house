require "open3"
require "rubygems/package"
require "stringio"
require "zlib"

module Backup
  # The disposable restore check from the VM-birth design (#246, "Restore
  # check"): before the switch goes on, prove a VM resident's backup brings
  # its home back. Reads the latest verified snapshot straight from the
  # house's own repository with restic (never through the VM), and checks:
  #
  #   * every file of the seed archive the resident was born from is in the
  #     snapshot's identity volume, byte for byte (files the resident or its
  #     runtime added since are listed, not failed)
  #   * the graph checkpoint in the snapshot is the one recorded at backup
  #
  # Nothing is written anywhere: restic's dump streams to this process, and
  # the tool container is removed afterwards. Run it on the house:
  #   bin/rails "vm:restore_check[AGENT_ID]"
  class VmRestoreCheck

    class Failed < StandardError; end

    DUMP_LIMIT = 256.megabytes
    TIMEOUT = 300

    Report = Data.define(:agent_id, :snapshot_id, :seed_files, :matched, :missing, :different, :added,
      :checkpoint_ok, :checkpoint_error) do
      def ok? = missing.empty? && different.empty? && checkpoint_ok

      def to_h
        super.merge(ok: ok?)
      end
    end

    def initialize(agent, capture: nil)
      @agent = agent
      @capture = capture
    end

    def call
      placement = Agents::RemoteRuntime.placement_for(agent)
      raise Failed, "Resident is not on a VM" unless placement&.backend == "hetzner_cloud"
      raise Failed, "Resident has no stored seed archive" if placement.seed_archive.blank?

      snapshot = AgentBackupSnapshot.where(agent:, ok: true).where.not(restic_snapshot_id: [ nil, "unknown" ])
        .order(:taken_at, :id).last || raise(Failed, "Resident has no verified backup")
      snapshot_id = snapshot.restic_snapshot_id

      seed = read_tar(Zlib.gunzip(placement.seed_archive))
      restored = read_tar(capture("dump", snapshot_id, "/data/identity"), strip: "identity/")
      missing = seed.keys.reject { |path| restored.key?(path) }.sort
      different = seed.keys.select { |path| restored.key?(path) && restored[path] != seed[path] }.sort
      added = (restored.keys - seed.keys).sort

      checkpoint_ok, checkpoint_error = check_checkpoint(snapshot)
      Report.new(agent_id: agent.id, snapshot_id:, seed_files: seed.size,
        matched: seed.size - missing.size - different.size, missing:, different:, added:,
        checkpoint_ok:, checkpoint_error:)
    end

    private

    attr_reader :agent

    # The checkpoint recorded for this snapshot by slice 4, checked by its own
    # verifier (exact bytes, envelope digest, resident uuid).
    def check_checkpoint(snapshot)
      return [ false, "VM backups (slice 4) are not on this house" ] unless defined?(VmBackup) && defined?(VmSnapshotVerifier)

      backup = VmBackup.find_by(agent_backup_snapshot_id: snapshot.id)
      return [ false, "No VM backup record for this snapshot" ] unless backup

      VmSnapshotVerifier.new(capture: method(:capture_for_verifier)).verify!(agent:, snapshot_id: snapshot.restic_snapshot_id,
        checkpoint_digest: backup.checkpoint_digest, checkpoint_file_digest: backup.checkpoint_file_digest)
      [ true, nil ]
    rescue StandardError => e
      [ false, "#{e.class}: #{e.message}" ]
    end

    def capture_for_verifier(_agent, *args) = capture(*args)

    # Regular files only, keyed by path relative to the volume root.
    def read_tar(bytes, strip: nil)
      files = {}
      Gem::Package::TarReader.new(StringIO.new(bytes)) do |tar|
        tar.each do |entry|
          next unless entry.file?

          path = entry.full_name.delete_prefix("/").delete_prefix("./")
          path = path.delete_prefix("data/") if strip
          path = path.delete_prefix(strip) if strip
          files[path] = entry.read.to_s.b
        end
      end
      files
    end

    def capture(*args)
      return @capture.call(*args).to_s.b if @capture
      raise Failed, "Live restore checks are disabled in tests" if Rails.env.test?

      name = "vm-restore-check-#{SecureRandom.hex(8)}"
      argv = [ "docker", "run", "--rm", "--name", name,
        "-e", "AWS_ACCESS_KEY_ID=#{AgentRestic.aws_value(:access_key_id)}",
        "-e", "AWS_SECRET_ACCESS_KEY=#{AgentRestic.aws_value(:secret_access_key)}",
        "-e", "AWS_DEFAULT_REGION=#{AgentRestic.region}",
        "-e", "RESTIC_PASSWORD=#{agent.restic_password}",
        "-e", "RESTIC_REPOSITORY=#{AgentRestic.repository_url(agent)}",
        AgentRestic::IMAGE, "--no-lock", "--no-cache", *args ]
      output = +"".b
      Open3.popen3(*argv) do |stdin, stdout, stderr, thread|
        stdin.close
        errors = Thread.new { stderr.read.to_s }
        Timeout.timeout(TIMEOUT) do
          while (chunk = stdout.read(1.megabyte))
            output << chunk
            raise Failed, "restic output exceeds #{DUMP_LIMIT} bytes" if output.bytesize > DUMP_LIMIT
          end
        end
        raise Failed, "restic #{args.first} failed: #{errors.value.last(500)}" unless thread.value.success?
      end
      output
    rescue Timeout::Error
      raise Failed, "restic #{args.first} timed out"
    ensure
      system("docker", "rm", "-f", name, out: File::NULL, err: File::NULL) if name && !@capture
    end

  end
end

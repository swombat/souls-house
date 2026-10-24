require "open3"
require "timeout"
require "rubygems/package"
require "stringio"
require "zlib"

module Backup
  # The readback check from the VM-birth design (#246, "Restore check"):
  # before the switch goes on, read a VM resident's backup back from storage
  # and compare it with what it was born from. This is readback evidence for
  # identity and checkpoint, not a full rerun of a recovery onto a new VM. Reads the latest verified snapshot straight from the
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
    # The same digest-pinned restic as slice 4's verifier and the VM's tool.
    IMAGE = "restic/restic@sha256:39d9072fb5651c80d75c7a811612eb60b4c06b32ffe87c2e9f3c7222e1797e76".freeze

    Report = Data.define(:agent_id, :snapshot_id, :seed_files, :matched, :missing, :different, :added,
      :checkpoint_ok, :checkpoint_error) do
      def ok? = missing.empty? && different.empty? && checkpoint_ok

      def to_h
        super.merge(ok: ok?)
      end
    end

    # capture replaces restic entirely (unit tests); argv_builder, cleanup and
    # timeout exercise the real bounded process handling with a fake child.
    def initialize(agent, capture: nil, argv_builder: nil, cleanup: nil, timeout: nil)
      @agent = agent
      @capture = capture
      @argv_builder = argv_builder
      @cleanup = cleanup
      @timeout = timeout
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
      raise Failed, "Live restore checks are disabled in tests" if Rails.env.test? && !@argv_builder

      name = "vm-restore-check-#{SecureRandom.hex(8)}"
      run_bounded(argv_for(name, args), name, args.first)
    end

    # The same bounded pattern as slice 4's verifier: the child runs in its
    # own process group, output is read concurrently under a byte limit,
    # stderr keeps only a short tail, a timeout kills the whole group before
    # waiting, and the tool container is removed by its unique name with a
    # bounded docker rm.
    def run_bounded(argv, name, what)
      output = +"".b
      tail = +"".b
      Open3.popen3(*argv, pgroup: true) do |stdin, stdout, stderr, thread|
        stdin.close
        reader = Thread.new do
          loop do
            output << stdout.readpartial(64.kilobytes)
            raise Failed, "restic output exceeds #{DUMP_LIMIT} bytes" if output.bytesize > DUMP_LIMIT
          end
        rescue EOFError
          nil
        end
        errors = Thread.new do
          loop do
            tail << stderr.readpartial(4.kilobytes)
            tail = tail.byteslice(-2.kilobytes, 2.kilobytes) || tail if tail.bytesize > 2.kilobytes
          end
        rescue EOFError
          nil
        end
        begin
          Timeout.timeout(@timeout || TIMEOUT) do
            reader.value
            errors.value
            raise Failed, "restic #{what} failed: #{tail.to_s.scrub.last(500)}" unless thread.value.success?
          end
        ensure
          Process.kill("KILL", -thread.pid) if thread.alive? rescue nil
          reader.join(5)
          errors.join(5)
        end
      end
      output
    rescue Timeout::Error
      raise Failed, "restic #{what} timed out"
    ensure
      cleanup(name)
    end

    def argv_for(name, args)
      return @argv_builder.call(name, args) if @argv_builder

      [ "docker", "run", "--rm", "--name", name,
        "-e", "AWS_ACCESS_KEY_ID=#{AgentRestic.aws_value(:access_key_id)}",
        "-e", "AWS_SECRET_ACCESS_KEY=#{AgentRestic.aws_value(:secret_access_key)}",
        "-e", "AWS_DEFAULT_REGION=#{AgentRestic.region}",
        "-e", "RESTIC_PASSWORD=#{agent.restic_password}",
        "-e", "RESTIC_REPOSITORY=#{AgentRestic.repository_url(agent)}",
        IMAGE, "--no-lock", "--no-cache", *args ]
    end

    def cleanup(name)
      return @cleanup.call(name) if @cleanup

      pid = Process.spawn("docker", "rm", "--force", name, out: File::NULL, err: File::NULL, pgroup: true)
      begin
        Timeout.timeout(10) { Process.wait(pid) }
      rescue Timeout::Error
        Process.kill("KILL", -pid) rescue nil
        Process.wait(pid) rescue nil
        raise Failed, "restore check container cleanup timed out"
      end
    end

  end
end

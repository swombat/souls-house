require "open3"

module Backup
  # Restores a resident's session transcripts from its latest verified
  # snapshot into a throwaway volume and says what came back (#969). Works for
  # residents on the shared host and on VMs alike: it reads the house's own
  # repository with restic, never through the resident or its server, and
  # writes nothing but the throwaway volume, which is removed afterwards.
  #
  # It never reads a transcript. It lists paths and sizes under the state
  # volume in the snapshot, and computes a SHA-256 only for paths it is
  # explicitly told to expect (synthetic test files). Anything under state
  # outside AgentRestic::TRANSCRIPT_PATHS is reported by path, because the
  # rest of the state volume holds credentials and must never be in a
  # snapshot. Run it on the house:
  #   bin/rails "backup:transcript_restore_check[AGENT_ID]"
  class TranscriptRestoreCheck

    class Failed < StandardError; end

    IMAGE = VmRestoreCheck::IMAGE
    INSPECT_IMAGE = AgentRestic::INSPECT_IMAGE
    STATE = "/data/state".freeze

    # Prints "F <bytes> <path>" for every regular file and "L <path>" for every
    # link under the restored state, then "H <sha256> <path>" for each
    # expected path ("H - <path>" when it is not there).
    INVENTORY = <<~'SH'.freeze
      root=/r/data/state
      if [ -d "$root" ]; then
        cd "$root"
        find . -type f -exec stat -c 'F %s %n' {} +
        find . -type l -exec sh -c 'for p; do echo "L $p"; done' sh {} +
      fi
      for p in "$@"; do
        if [ -f "$root/$p" ] && [ ! -L "$root/$p" ]; then
          echo "H $(sha256sum "$root/$p" | cut -d' ' -f1) $p"
        else
          echo "H - $p"
        fi
      done
    SH

    Report = Data.define(:agent_id, :snapshot_id, :taken_at, :by_path, :files, :bytes, :outside, :links,
      :expected, :refused) do
      def ok? = outside.empty? && links.empty? && expected.values.all? { it[:ok] } && refused.values.none?

      def to_h
        super.merge(ok: ok?)
      end
    end

    # expect: { "claude/projects/x/y.jsonl" => sha256 } must come back with that digest.
    # refuse: [ "secrets/x" ] paths (relative to the state volume) that must not come back.
    # run: replaces docker in tests; called with an argv, returns [stdout, success].
    def initialize(agent, expect: {}, refuse: [], snapshot: nil, run: nil)
      @agent = agent
      @expect = expect.to_h.transform_keys { clean(it) }
      @refuse = refuse.map { clean(it) }
      @snapshot = snapshot
      @run = run
    end

    def call
      snapshot = @snapshot || AgentBackupSnapshot.where(agent:, ok: true).where.not(restic_snapshot_id: [ nil, "unknown" ])
        .order(:taken_at, :id).last || raise(Failed, "Resident has no verified backup")
      volume = "transcript-restore-check-#{SecureRandom.hex(6)}"
      docker!("volume", "create", "--label", "souls_house.purpose=transcript-restore-check", volume)
      begin
        docker!("run", "--rm", "-v", "#{volume}:/r", *restic_env, IMAGE, "--no-lock", "--no-cache",
          "restore", snapshot.restic_snapshot_id, "--target", "/r", "--include", STATE)
        listing = docker!("run", "--rm", "--network", "none", "-v", "#{volume}:/r:ro", INSPECT_IMAGE,
          "sh", "-c", INVENTORY, "inventory", *(@expect.keys + @refuse).uniq)
      ensure
        docker("volume", "rm", "-f", volume)
      end
      report(snapshot, listing)
    end

    private

    attr_reader :agent

    def report(snapshot, listing)
      files = {}
      links = []
      hashes = {}
      listing.each_line do |line|
        kind, rest = line.chomp.split(" ", 2)
        case kind
        when "F"
          size, path = rest.split(" ", 2)
          files[clean(path)] = size.to_i
        when "L" then links << clean(rest)
        when "H"
          digest, path = rest.split(" ", 2)
          hashes[clean(path)] = digest == "-" ? nil : digest
        end
      end

      by_path = AgentRestic::TRANSCRIPT_PATHS.index_with do |prefix|
        mine = files.select { |path, _| under?(path, prefix) }
        { files: mine.size, bytes: mine.values.sum }
      end
      outside = files.keys.reject { |path| AgentRestic::TRANSCRIPT_PATHS.any? { under?(path, it) } }.sort
      expected = @expect.to_h do |path, digest|
        [ path, { present: !hashes[path].nil?, ok: hashes[path] == digest } ]
      end
      refused = @refuse.to_h { |path| [ path, files.key?(path) || hashes[path].present? ] }

      Report.new(agent_id: agent.id, snapshot_id: snapshot.restic_snapshot_id, taken_at: snapshot.taken_at,
        by_path:, files: files.size, bytes: files.values.sum, outside:, links: links.sort, expected:, refused:)
    end

    def under?(path, prefix) = path == prefix || path.start_with?("#{prefix}/")

    def clean(path) = path.to_s.delete_prefix("./").delete_prefix("/")

    def restic_env
      [
        "-e", "AWS_ACCESS_KEY_ID=#{AgentRestic.aws_value(:access_key_id)}",
        "-e", "AWS_SECRET_ACCESS_KEY=#{AgentRestic.aws_value(:secret_access_key)}",
        "-e", "AWS_DEFAULT_REGION=#{AgentRestic.region}",
        "-e", "RESTIC_PASSWORD=#{agent.restic_password}",
        "-e", "RESTIC_REPOSITORY=#{AgentRestic.repository_url(agent)}"
      ]
    end

    def docker!(*args)
      out, ok = docker(*args)
      raise Failed, "docker #{args.first} #{args[1] if args.first == 'volume'} failed".squish unless ok
      out
    end

    def docker(*args)
      return @run.call([ "docker", *args ]) if @run
      raise Failed, "Live restore checks are disabled in tests" if Rails.env.test?

      out, _err, status = Open3.capture3("docker", *args)
      [ out, status.success? ]
    end

  end
end

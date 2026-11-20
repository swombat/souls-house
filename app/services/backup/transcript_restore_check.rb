require "open3"
require "timeout"

module Backup
  # What a resident's latest verified backup holds of its session transcripts
  # (#969), for residents on the shared host and on VMs alike: both write to
  # the same per-resident repository, which this reads with restic, never
  # through the resident or its server.
  #
  # Two modes, and neither ever reads a transcript.
  #
  # * Baseline (no EXPECT): metadata only. `restic ls` of /data/state in the
  #   snapshot, aggregated into file counts and bytes per transcript path.
  #   Nothing is restored, and no resident path is printed: paths outside
  #   AgentRestic::TRANSCRIPT_PATHS and links are counted, not listed. A
  #   snapshot with no transcript files is "no_transcript_data", never a pass.
  # * Restore (EXPECT given): for synthetic test files only. /data/state is
  #   restored into a throwaway volume; scope and REFUSE are checked from the
  #   listing (path metadata); only the EXPECT paths are hashed, and only after
  #   each one is checked to sit under a transcript path with no link on any
  #   component. Passes only as "recovered", when every expected file came
  #   back with its digest, nothing is out of scope and nothing refused is
  #   there.
  #
  # EXPECT paths are synthetic, so their grammar is narrow: every component is
  # made of letters, digits, ".", "_" and "-" (no spaces, no glob characters),
  # refused before Docker otherwise. The inventory walks them literally anyway.
  # REFUSE covers regular files, directories and symlinks (what the listing
  # records), not other special files.
  #
  # The throwaway volume and the named tool containers are always removed,
  # and their absence is checked afterwards; if one is left, the report names
  # it and is not green, and a primary failure is never hidden by a cleanup
  # one.
  #   bin/rails "backup:transcript_restore_check[AGENT_ID]"
  class TranscriptRestoreCheck

    class Failed < StandardError; end

    IMAGE = VmRestoreCheck::IMAGE
    INSPECT_IMAGE = AgentRestic::INSPECT_IMAGE
    STATE = "/data/state".freeze
    DIGEST = /\A\h{64}\z/
    COMPONENT = /\A[A-Za-z0-9._-]+\z/
    TIMEOUT = 600
    LIST_LIMIT = 64.megabytes

    # Run inside the inspect container with the restored volume at /r (ROOT
    # overrides it in tests). Prints "F <bytes> <path>" per regular file,
    # "D <path>" per directory and "L <path>" per link under the restored
    # state (paths, never contents), then "H <verdict> <path>" for each
    # expected path: a SHA-256, or absent / link / notfile. Expected paths are
    # walked one literal component at a time (no word splitting, no globbing).
    # The state root and each of its parents are checked for links first; a
    # linked one prints "LINKEDROOT" and nothing is listed or hashed.
    # Any failure exits non-zero, and a complete listing ends with "END";
    # anything else is an error, never an empty result.
    INVENTORY = <<~'SH'.freeze
      set -euf
      root="${ROOT:-/r/data/state}"
      up="$root"
      while [ -n "$up" ] && [ "$up" != "/" ]; do
        if [ -L "$up" ]; then echo "LINKEDROOT"; echo "END"; exit 0; fi
        up="${up%/*}"
      done
      if [ -d "$root" ]; then
        cd "$root"
        find . -type f -exec stat -c 'F %s %n' {} +
        find . -mindepth 1 -type d -exec sh -c 'for p; do echo "D $p"; done' sh {} +
        find . -type l -exec sh -c 'for p; do echo "L $p"; done' sh {} +
      else
        echo "NOSTATE"
      fi
      for p in "$@"; do
        cur="$root"; verdict=ok; rest="$p"
        while [ -n "$rest" ]; do
          part="${rest%%/*}"
          case "$rest" in */*) rest="${rest#*/}" ;; *) rest="" ;; esac
          cur="$cur/$part"
          if [ -L "$cur" ]; then verdict=link; break; fi
          if [ ! -e "$cur" ]; then verdict=absent; break; fi
        done
        if [ "$verdict" = ok ] && [ ! -f "$cur" ]; then verdict=notfile; fi
        if [ "$verdict" = ok ]; then
          digest=$(sha256sum "$cur" | cut -d' ' -f1)
          [ -n "$digest" ]
          echo "H $digest $p"
        else
          echo "H $verdict $p"
        fi
      done
      echo "END"
    SH

    Report = Data.define(:agent_id, :snapshot_id, :taken_at, :mode, :verdict, :by_path, :files, :bytes,
      :outside_count, :link_count, :expected, :refused, :cleanup) do
      def ok? = %w[recovered present].include?(verdict) && cleanup[:ok]

      def to_h
        super.merge(ok: ok?)
      end
    end

    # expect: { "claude/projects/x/y.jsonl" => sha256 } synthetic files that
    #   must come back with that digest (paths relative to the state volume).
    # refuse: paths that must not be in the snapshot at all; checked from
    #   the listing only, never opened.
    # run: replaces docker in tests; called with an argv, returns [stdout, success].
    def initialize(agent, expect: {}, refuse: [], snapshot: nil, run: nil, timeout: TIMEOUT)
      @agent = agent
      @expect = expect.to_h.to_h { |path, digest| [ clean(path), digest ] }
      @refuse = refuse.map { clean(it) }
      @snapshot = snapshot
      @run = run
      @timeout = timeout
      @leftover_containers = []
      validate!
    end

    def call
      snapshot = @snapshot || AgentBackupSnapshot.where(agent:, ok: true).where.not(restic_snapshot_id: [ nil, "unknown" ])
        .order(:taken_at, :id).last || raise(Failed, "Resident has no verified backup")
      @expect.empty? ? baseline(snapshot) : restore(snapshot)
    end

    private

    attr_reader :agent

    def validate!
      @expect.each do |path, digest|
        raise ArgumentError, "EXPECT #{path}: a 64-hex SHA-256 is required" unless digest.is_a?(String) && digest.match?(DIGEST)
        raise ArgumentError, "EXPECT #{path}: not under a transcript path" unless transcript?(path)
        parts = path.split("/", -1)
        unless parts.all? { it.match?(COMPONENT) } && !parts.intersect?([ ".", ".." ])
          raise ArgumentError, "EXPECT #{path}: only simple synthetic names (letters, digits, . _ -) are allowed"
        end
      end
      @refuse.each do |path|
        raise ArgumentError, "REFUSE path is empty" if path.blank?
        raise ArgumentError, "REFUSE #{path}: also expected" if @expect.key?(path)
      end
    end

    # Metadata only: nothing restored, nothing hashed, no path printed.
    def baseline(snapshot)
      name = container_name
      out = run_tool(name, "run", "--rm", "--name", name, *restic_env, IMAGE, "--no-lock", "--no-cache",
        "ls", "--json", "--recursive", snapshot.restic_snapshot_id, STATE)
      files = {}
      dirs = []
      links = []
      seen_snapshot = false
      out.each_line do |line|
        node = JSON.parse(line)
        kind = node["struct_type"] || node["message_type"]
        if kind == "snapshot"
          seen_snapshot = true
          next
        end
        next unless kind == "node"

        path = node["path"].to_s
        next unless path.start_with?("#{STATE}/")

        relative = path.delete_prefix("#{STATE}/")
        case node["type"]
        when "file" then files[relative] = node["size"].to_i
        when "dir" then dirs << relative
        when "symlink" then links << relative
        end
      rescue JSON::ParserError
        raise Failed, "restic ls returned an unreadable line"
      end
      raise Failed, "restic ls did not describe the snapshot" unless seen_snapshot

      summary(snapshot, mode: "baseline", files:, links:, expected: {}, refused: refused_from(files, dirs, links),
        cleanup: container_cleanup({ ok: true })) do |transcript_files, refused|
        if refused.values.any? || outside(files).any? || links.any? then "failed"
        elsif transcript_files.zero? then "no_transcript_data"
        else "present"
        end
      end
    end

    def restore(snapshot)
      volume = "transcript-restore-check-#{SecureRandom.hex(6)}"
      cleanup = { ok: true, volume: }
      primary = nil
      begin
        _, created = docker("volume", "create", "--label", "souls_house.purpose=transcript-restore-check", volume)
        raise Failed, "docker volume create failed" unless created

        name = container_name
        run_tool(name, "run", "--rm", "--name", name, "-v", "#{volume}:/r", *restic_env, IMAGE, "--no-lock", "--no-cache",
          "restore", snapshot.restic_snapshot_id, "--target", "/r", "--include", STATE)
        name = container_name
        listing = run_tool(name, "run", "--rm", "--name", name, "--network", "none", "-v", "#{volume}:/r:ro", INSPECT_IMAGE,
          "sh", "-c", INVENTORY, "inventory", *@expect.keys)
      rescue StandardError => error
        primary = error
      ensure
        _, removed = (docker("volume", "rm", "-f", volume) rescue [ nil, false ])
        cleanup = { ok: false, volume:, error: "docker volume rm failed; remove #{volume} by hand" } unless removed
      end
      if primary
        left = []
        left << "the throwaway volume #{volume}" unless cleanup[:ok]
        left << "containers #{@leftover_containers.join(', ')}" if @leftover_containers.any?
        raise primary if left.empty?

        raise Failed, "#{primary.message} (and #{left.join(' and ')} was not removed)"
      end

      cleanup = container_cleanup(cleanup)
      files, dirs, links, hashes = parse_inventory(listing)
      expected = @expect.to_h do |path, digest|
        verdict = hashes.fetch(path) { raise Failed, "inventory has no verdict for #{path}" }
        [ path, { state: verdict.match?(DIGEST) ? (verdict == digest ? "match" : "different") : verdict, ok: verdict == digest } ]
      end
      summary(snapshot, mode: "restore", files:, links:, expected:, refused: refused_from(files, dirs, links), cleanup:) do |_count, refused|
        if expected.values.all? { it[:ok] } && refused.values.none? && outside(files).empty? && links.empty?
          "recovered"
        else
          "failed"
        end
      end
    end

    def parse_inventory(listing)
      lines = listing.to_s.lines.map(&:chomp)
      raise Failed, "inventory incomplete (no END)" unless lines.last == "END"
      raise Failed, "restored state root or one of its parents is a link; nothing was listed or hashed" if lines.include?("LINKEDROOT")

      files = {}
      dirs = []
      links = []
      hashes = {}
      lines[0...-1].each do |line|
        kind, rest = line.split(" ", 2)
        case kind
        when "F"
          size, path = rest.to_s.split(" ", 2)
          raise Failed, "inventory line unreadable" unless size.to_s.match?(/\A\d+\z/) && path.present?
          files[clean(path)] = size.to_i
        when "D" then dirs << clean(rest)
        when "L" then links << clean(rest)
        when "H"
          verdict, path = rest.to_s.split(" ", 2)
          raise Failed, "inventory line unreadable" unless path.present? && (verdict.match?(DIGEST) || %w[absent link notfile].include?(verdict))
          hashes[clean(path)] = verdict
        when "NOSTATE" then nil
        else raise Failed, "inventory line unreadable"
        end
      end
      [ files, dirs, links, hashes ]
    end

    def summary(snapshot, mode:, files:, links:, expected:, refused:, cleanup:)
      by_path = AgentRestic::TRANSCRIPT_PATHS.index_with do |prefix|
        mine = files.select { |path, _| under?(path, prefix) }
        { files: mine.size, bytes: mine.values.sum }
      end
      transcript_files = by_path.values.sum { it[:files] }
      verdict = yield(transcript_files, refused)
      Report.new(agent_id: agent.id, snapshot_id: snapshot.restic_snapshot_id, taken_at: snapshot.taken_at, mode:, verdict:,
        by_path:, files: files.size, bytes: files.values.sum, outside_count: outside(files).size, link_count: links.size,
        expected:, refused:, cleanup:)
    end

    # From the listing alone: a refused path is there if it, or anything under
    # it, is listed as a file, directory or link.
    def refused_from(files, dirs, links)
      listed = files.keys + dirs + links
      @refuse.index_with { |path| listed.any? { under?(it, path) } }
    end

    def outside(files) = files.keys.reject { transcript?(it) }

    def transcript?(path) = AgentRestic::TRANSCRIPT_PATHS.any? { under?(path, it) }

    def under?(path, prefix) = path == prefix || path.start_with?("#{prefix}/")

    def clean(path) = path.to_s.delete_prefix("./").delete_prefix("/")

    def container_name = "transcript-restore-check-#{SecureRandom.hex(8)}"

    def restic_env
      [
        "-e", "AWS_ACCESS_KEY_ID=#{AgentRestic.aws_value(:access_key_id)}",
        "-e", "AWS_SECRET_ACCESS_KEY=#{AgentRestic.aws_value(:secret_access_key)}",
        "-e", "AWS_DEFAULT_REGION=#{AgentRestic.region}",
        "-e", "RESTIC_PASSWORD=#{agent.restic_password}",
        "-e", "RESTIC_REPOSITORY=#{AgentRestic.repository_url(agent)}"
      ]
    end

    # A named tool container, removed afterwards whatever happened; one still
    # there after removal is recorded (an already-absent one is fine).
    def run_tool(name, *args)
      out, ok = docker(*args)
      raise Failed, "docker #{args.include?('restore') ? 'restore' : args.include?('ls') ? 'ls' : 'inventory'} failed" unless ok

      out
    ensure
      docker("rm", "-f", name) rescue nil
      left, listed = (docker("ps", "-aq", "--filter", "name=^#{name}$") rescue [ nil, false ])
      @leftover_containers << name unless listed && left.to_s.strip.empty?
    end

    def container_cleanup(cleanup)
      return cleanup if @leftover_containers.empty?

      cleanup.merge(ok: false, containers: @leftover_containers.dup,
        error: [ cleanup[:error], "containers not removed: #{@leftover_containers.join(', ')}" ].compact.join("; "))
    end

    def docker(*args)
      return @run.call([ "docker", *args ]) if @run
      raise Failed, "Live restore checks are disabled in tests" if Rails.env.test?

      bounded([ "docker", *args ])
    end

    # The child runs in its own process group with a deadline; on timeout the
    # whole group is killed (VmRestoreCheck's pattern).
    def bounded(argv)
      out = +""
      ok = false
      Open3.popen3(*argv, pgroup: true) do |stdin, stdout, stderr, thread|
        stdin.close
        reader = Thread.new do
          loop do
            out << stdout.readpartial(64.kilobytes)
            raise Failed, "docker output exceeds #{LIST_LIMIT} bytes" if out.bytesize > LIST_LIMIT
          end
        rescue EOFError
          nil
        end
        drain = Thread.new do
          loop { stderr.readpartial(64.kilobytes) }
        rescue EOFError, IOError
          nil
        end
        begin
          Timeout.timeout(@timeout) do
            reader.value
            drain.join
            ok = thread.value.success?
          end
        rescue Timeout::Error
          raise Failed, "docker #{argv[1]} timed out"
        ensure
          Process.kill("KILL", -thread.pid) if thread.alive? rescue nil
          reader.join(5)
          drain.join(5)
        end
      end
      [ out, ok ]
    end

  end
end

require "open3"
require "timeout"

module Agents
  class JournalEntryStats

    class MeasurementError < StandardError; end

    # Count conventional second-level entry headings, ignoring fenced examples.
    # Only the aggregate leaves the resident's filesystem. No symlink traversal.
    SCRIPT = <<~'PYTHON'
      import json, os, pathlib, re, stat, subprocess, sys
      root = pathlib.Path("/home/agent/identity/memory/daily-journals")
      # One Markdown file under memory/ when the resident chose one (argv), else
      # the dated daily journals. The rule is Agent.valid_journal_source?.
      source = sys.argv[1] if len(sys.argv) > 1 else None
      def count_entries(journal):
          count = 0
          fence = None
          with journal:
              for line in journal:
                  marker = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
                  if marker:
                      run = marker[1]
                      if fence is None:
                          fence = run
                      elif run[0] == fence[0] and len(run) >= len(fence):
                          fence = None
                      continue
                  if fence is None and re.match(r"^##[ \t]+\S", line):
                      count += 1
          return count
      count = 0
      if source is None:
          if any(path.is_symlink() for path in (root, root.parent, root.parent.parent)):
              raise RuntimeError("invalid journal directory")
          try:
              paths = list(root.iterdir())
          except FileNotFoundError:
              paths = []
          for path in paths:
              if not re.fullmatch(r"\d{4}-\d{2}-\d{2}\.md", path.name) or path.is_symlink() or not path.is_file():
                  continue
              count += count_entries(path.open(encoding="utf-8"))
      else:
          segments = source.split("/")
          if (len(source) > 200 or not source.endswith(".md") or len(segments) < 2 or segments[0] != "memory"
                  or any(not re.fullmatch(r"[A-Za-z0-9_.-]+", segment) or not segment.strip(".") for segment in segments)):
              raise RuntimeError("invalid journal source")
          # Opened step by step without following links, so a link swapped in
          # after any check is refused at open, not followed.
          directory = os.open(str(root.parent.parent), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
          try:
              for segment in segments[:-1]:
                  inner = os.open(segment, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
                  os.close(directory)
                  directory = inner
              handle = os.open(segments[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
          finally:
              os.close(directory)
          if not stat.S_ISREG(os.fstat(handle).st_mode):
              os.close(handle)
              raise RuntimeError("journal source is not a file")
          count = count_entries(os.fdopen(handle, encoding="utf-8"))
      # Allocated bytes, including hidden files; du does not follow symlinks.
      # Explicit volume roots exclude the image layer and temporary filesystems.
      storage_bytes = None
      try:
          roots = ["/home/agent/" + name for name in ("identity", ".chaos", "repo", "work", "state")]
          if any(pathlib.Path(path).is_symlink() for path in roots):
              raise ValueError("invalid volume root")
          measurement = subprocess.run(["du", "-s", "-B1", "--", *roots], capture_output=True, text=True, timeout=10, check=True)
          sizes = [int(line.split()[0]) for line in measurement.stdout.splitlines()]
          if len(sizes) == len(roots) and all(size >= 0 for size in sizes):
              storage_bytes = sum(sizes)
      except (OSError, ValueError, subprocess.SubprocessError):
          pass
      print(json.dumps({"count": count, "storage_bytes": storage_bytes}))
    PYTHON

    def initialize(agent)
      @agent = agent
    end

    def call
      raise MeasurementError if @agent.container_name.blank?
      return remote if Agents::RemoteRuntime.remote?(@agent)

      raise MeasurementError if @agent.sandbox_host.present? && @agent.sandbox_host != Config.sandbox_host

      Agents::Resources.new(@agent).verify_existing!
      result = capture
      raise MeasurementError unless result[:ok]

      measurement = JSON.parse(result[:stdout])
      count = measurement.fetch("count")
      raise MeasurementError unless count.is_a?(Integer) && count >= 0

      bytes = measurement["storage_bytes"]
      bytes = nil unless bytes.is_a?(Integer) && bytes >= 0
      { status: "measured", count: count, storage_bytes: bytes, measured_at: Time.current.iso8601 }
    rescue MeasurementError, Agents::Resources::OwnershipError, Timeout::Error,
           SystemCallError, JSON::ParserError, KeyError
      @agent.journal_entry_stats.merge("status" => "unavailable")
    end

    private

    # A resident on its own server (#246): the same script, run by its runner.
    def remote
      measurement = Agents::RemoteRuntime.home_stats!(@agent)
      raise MeasurementError unless measurement.is_a?(Hash)

      count = measurement["count"]
      raise MeasurementError unless count.is_a?(Integer) && count >= 0

      bytes = measurement["storage_bytes"]
      bytes = nil unless bytes.is_a?(Integer) && bytes >= 0
      { status: "measured", count: count, storage_bytes: bytes, measured_at: Time.current.iso8601 }
    rescue MeasurementError, Agents::RemoteRuntime::Unavailable
      @agent.journal_entry_stats.merge("status" => "unavailable")
    end

    def capture
      # The chosen journal goes in as one argv value, never into the code.
      Open3.popen3("docker", "exec", @agent.container_name,
        "timeout", "30", "python3", "-c", SCRIPT, *@agent.journal_source, pgroup: true) do |stdin, stdout, stderr, process|
        stdin.close
        output = Thread.new { stdout.read }
        errors = Thread.new { stderr.read }
        begin
          Timeout.timeout(45) do
            { ok: process.value.success?, stdout: output.value }
          end
        ensure
          if process.alive?
            Process.kill("KILL", -process.pid)
            process.join
          end
          output.join
          errors.join
        end
      end
    end

  end
end

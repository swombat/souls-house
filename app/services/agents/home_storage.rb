module Agents
  # The disk use on a resident's card: allocated bytes across its five
  # persistent volumes, walked inside the resident by a fixed script. Apart
  # from the journal count because the walk is slow: 13 s for an 83 GB home
  # and 17 s for a 122 GB one with a warm cache (jZWPXJ, 23 Nov 2026), past
  # the 10 s the count script used to give it, so the largest homes read "—"
  # forever. It runs on its own slower clock (AgentHomeStorageJob).
  #
  # Returns the card's home_storage:
  #   "measured"   bytes and measured_at are this walk's.
  #   "too_slow"   the walk ran out of time; bytes, if any, are an older walk's.
  #   "unavailable" no answer (no container, runner too old, a failed exec);
  #                bytes, if any, are an older walk's. "reason" says which,
  #                in the house's words, never the resident's output.
  # attempted_at is always this attempt.
  class HomeStorage

    class MeasurementError < StandardError; end

    # The walk's budget inside a resident on this host, and the exec's
    # around it. One walk at a time runs here (AgentHomeStorageJob), so a
    # slow one delays only other walks. A VM's runner gives it far less
    # (HOME_STORAGE_SECONDS there): it answers commands one at a time.
    DU_SECONDS = 150
    EXEC_SECONDS = DU_SECONDS + 20

    # Allocated bytes, including hidden files; du does not follow symlinks.
    # Explicit volume roots exclude the image layer and temporary filesystems.
    # Only the total, or the name of what went wrong, leaves the resident.
    SCRIPT = <<~'PYTHON'
      import json, pathlib, subprocess, sys
      # The walk's budget in seconds: one argv value, bounded here too.
      budget = max(1, min(int(sys.argv[1]), 600))
      roots = ["/home/agent/" + name for name in ("identity", ".chaos", "repo", "work", "state")]
      try:
          if any(pathlib.Path(path).is_symlink() for path in roots):
              raise ValueError("invalid volume root")
          measurement = subprocess.run(["du", "-s", "-B1", "--", *roots], capture_output=True, text=True, timeout=budget, check=True)
          sizes = [int(line.split()[0]) for line in measurement.stdout.splitlines()]
          if len(sizes) != len(roots) or any(size < 0 for size in sizes):
              raise ValueError("unreadable sizes")
          print(json.dumps({"storage_bytes": sum(sizes)}))
      except subprocess.TimeoutExpired:
          print(json.dumps({"error": "timeout"}))
      except (OSError, ValueError, IndexError, subprocess.SubprocessError):
          print(json.dumps({"error": "failed"}))
    PYTHON

    def initialize(agent)
      @agent = agent
    end

    def call
      attempted_at = Time.current.iso8601
      measurement = Agents::RemoteRuntime.remote?(@agent) ? remote : local
      bytes = measurement["storage_bytes"]
      if bytes.is_a?(Integer) && bytes >= 0
        return { "status" => "measured", "bytes" => bytes, "measured_at" => attempted_at, "attempted_at" => attempted_at }
      end
      raise MeasurementError, "the walk failed" unless measurement["error"] == "timeout"

      previous.merge("status" => "too_slow", "attempted_at" => attempted_at).except("reason")
    rescue Agents::RemoteRuntime::RunnerTooOld
      previous.merge("status" => "unavailable", "reason" => "runner_too_old", "attempted_at" => attempted_at)
    rescue MeasurementError, Agents::Resources::OwnershipError, Agents::RemoteRuntime::Unavailable,
           Timeout::Error, SystemCallError, JSON::ParserError
      previous.merge("status" => "unavailable", "reason" => "failed", "attempted_at" => attempted_at)
    end

    private

    # Only an earlier walk's figure is kept, never its status.
    def previous
      @agent.home_storage.to_h.slice("bytes", "measured_at")
    end

    def local
      raise MeasurementError, "no container" if @agent.container_name.blank?
      raise MeasurementError, "another host's resident" if @agent.sandbox_host.present? && @agent.sandbox_host != Config.sandbox_host

      Agents::Resources.new(@agent).verify_existing!
      result = capture
      raise MeasurementError, "the walk failed" unless result[:ok]

      parse(result[:stdout])
    end

    # A resident on its own server: the runner's fixed copy of SCRIPT.
    def remote
      measurement = Agents::RemoteRuntime.home_storage!(@agent)
      raise MeasurementError, "unreadable" unless measurement.is_a?(Hash)

      measurement
    end

    def capture
      ResidentPython.run(@agent.container_name, SCRIPT, DU_SECONDS.to_s, seconds: EXEC_SECONDS)
    end

    def parse(stdout)
      measurement = JSON.parse(stdout.to_s.strip.lines.last.to_s)
      raise MeasurementError, "unreadable" unless measurement.is_a?(Hash)

      measurement
    end

  end
end

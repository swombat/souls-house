module Agents
  # The disk use on a VM resident's card. A resident on the house host is
  # walked daily by Agents::StorageUsage (storage_usage), which the card
  # shows; that walker can't reach a VM's volumes, and its totals are the
  # house host's disk, so a VM's figure is kept apart, here, in home_storage.
  # The VM's runner walks the five volumes with its byte-for-byte copy of
  # SCRIPT under its own short budget (home_stats v3, part "storage"):
  # it answers one command at a time, so the walk must not hold a turn.
  #
  # Before #1111 this rode along with the journal count under a 10 s du, and
  # the largest homes read "—" forever (jZWPXJ: 120 GB took 109 s cold).
  #
  # Returns home_storage:
  #   "measured"    bytes and measured_at are this walk's.
  #   "too_slow"    the walk ran out of time; bytes, if any, are an older walk's.
  #   "unavailable" no answer (runner too old, failed, unreadable); bytes, if
  #                 any, are an older walk's. "reason" says which, in the
  #                 house's words, never the resident's output.
  # attempted_at is always this attempt.
  class HomeStorage

    class MeasurementError < StandardError; end

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
      raise MeasurementError, "not on its own server" unless Agents::RemoteRuntime.remote?(@agent)

      measurement = Agents::RemoteRuntime.home_storage!(@agent)
      raise MeasurementError, "unreadable" unless measurement.is_a?(Hash)

      bytes = measurement["storage_bytes"]
      if bytes.is_a?(Integer) && bytes >= 0
        return { "status" => "measured", "bytes" => bytes, "measured_at" => attempted_at, "attempted_at" => attempted_at }
      end
      raise MeasurementError, "the walk failed" unless measurement["error"] == "timeout"

      previous.merge("status" => "too_slow", "attempted_at" => attempted_at)
    rescue Agents::RemoteRuntime::RunnerTooOld
      previous.merge("status" => "unavailable", "reason" => "runner_too_old", "attempted_at" => attempted_at)
    rescue MeasurementError, Agents::RemoteRuntime::Unavailable
      previous.merge("status" => "unavailable", "reason" => "failed", "attempted_at" => attempted_at)
    end

    private

    # Only an earlier walk's figure is kept, never its status.
    def previous
      @agent.home_storage.to_h.slice("bytes", "measured_at")
    end

  end
end

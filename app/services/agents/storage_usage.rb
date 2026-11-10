require "open3"
require "timeout"

module Agents
  class StorageUsage

    class MeasurementError < StandardError; end

    # du's own budget inside the helper. Large homes (130–150 GB of work
    # volume) take 16–30 s on the host; the margin covers a cold cache.
    DU_SECONDS = 300
    # The docker CLI call that runs du gets a little longer than du itself,
    # so the helper's own timeout fires first and the reason is ours.
    RUN_SECONDS = DU_SECONDS + 30
    COMMAND_SECONDS = 30

    def initialize(agent)
      @agent = agent
    end

    def call
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return { status: "not_applicable" } unless @agent.hosted?
      return { status: "unavailable", checked_at: Time.current.iso8601 } if @agent.uuid.blank?

      # Use the same Docker daemon as sandbox provisioning, never a guessed host.
      if @agent.sandbox_host.present? && @agent.sandbox_host != Config.sandbox_host
        raise MeasurementError, "other_host"
      end

      names = VolumeSet.new(@agent).names
      # Inspect before mounting: Docker must never create an absent volume.
      existing = names.select { |_key, name| capture("volume", "inspect", name, "--format", "{{.Name}}")[:ok] }
      raise MeasurementError, "no_volumes" if existing.empty?

      mounts = existing.flat_map do |key, name|
        [ "--mount", "type=volume,src=#{name},dst=/measure/#{key},readonly" ]
      end
      @helper_name = "admin-storage-#{SecureRandom.hex(10)}"
      # --init: without it busybox `timeout` execs du as PID 1, which ignores
      # SIGTERM, so the inner timeout never fired and every large home ran
      # into the outer kill instead. nice keeps the walk behind residents.
      result = capture(
        "run", "--rm", "--init", "--name", @helper_name, "--network", "none", "--read-only",
        "--memory", "64m", "--cpus", "1", "--pids-limit", "32", *mounts,
        "busybox:1.37", "nice", "-n", "19", "timeout", DU_SECONDS.to_s,
        "du", "-sk", *existing.keys.map { |key| "/measure/#{key}" },
        seconds: RUN_SECONDS
      )
      raise MeasurementError, "du_failed" unless result[:ok]

      volumes = result[:stdout].lines.to_h do |line|
        match = line.match(/\A(\d+)\s+\/measure\/(identity|chaos|repo|work|state)\s*\z/)
        raise MeasurementError unless match

        [ match[2], Integer(match[1]) * 1024 ]
      end
      raise MeasurementError unless volumes.keys.sort == existing.keys.map(&:to_s).sort

      {
        status: existing.size == names.size ? "measured" : "partial",
        bytes: volumes.values.sum, volumes: volumes,
        missing_volumes: (names.keys - existing.keys).map(&:to_s),
        measured_at: Time.current.iso8601, checked_at: Time.current.iso8601,
        attempt_seconds: elapsed(started)
      }
    rescue Agents::Resources::OwnershipError, MeasurementError, Timeout::Error, SystemCallError, KeyError => e
      # Preserve the last reading, but never present it as a successful refresh.
      # The reason and duration say why, so a measurement that can never
      # finish shows as one instead of an old number that looks current.
      @agent.storage_usage.except("failure", "attempt_seconds").merge(
        "status" => "unavailable", "checked_at" => Time.current.iso8601,
        "failure" => failure_reason(e), "attempt_seconds" => elapsed(started)
      )
    ensure
      remove_helper if @helper_name
    end

    private

    def elapsed(started)
      return nil unless started

      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)
    end

    def failure_reason(error)
      case error
      when Timeout::Error then "timeout"
      when Agents::Resources::OwnershipError then "ownership"
      when MeasurementError
        %w[other_host no_volumes du_failed].include?(error.message) ? error.message : "unreadable"
      else "docker_unavailable"
      end
    end

    def remove_helper
      capture("rm", "-f", @helper_name)
    rescue Timeout::Error, SystemCallError
      # The helper also has an internal timeout and --rm. A daemon outage
      # must not turn an unavailable measurement into a failed admin job.
      nil
    end

    def capture(*args, seconds: COMMAND_SECONDS)
      Agents::Resources.new(@agent).verify_existing!
      Open3.popen3("docker", *args, pgroup: true) do |stdin, stdout, stderr, process|
        stdin.close
        output = Thread.new { stdout.read }
        errors = Thread.new { stderr.read }
        begin
          Timeout.timeout(seconds) do
            { ok: process.value.success?, stdout: output.value, stderr: errors.value }
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

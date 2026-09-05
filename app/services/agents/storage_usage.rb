require "open3"
require "timeout"

module Agents
  class StorageUsage

    class MeasurementError < StandardError; end

    def initialize(agent)
      @agent = agent
    end

    def call
      return { status: "not_applicable" } unless @agent.hosted?
      return { status: "unavailable", checked_at: Time.current.iso8601 } if @agent.uuid.blank?

      # Use the same Docker daemon as sandbox provisioning, never a guessed host.
      if @agent.sandbox_host.present? && @agent.sandbox_host != Config.sandbox_host
        raise MeasurementError
      end

      names = VolumeSet.new(@agent).names
      # Inspect before mounting: Docker must never create an absent volume.
      existing = names.select { |_key, name| capture("volume", "inspect", name, "--format", "{{.Name}}")[:ok] }
      raise MeasurementError if existing.empty?

      mounts = existing.flat_map do |key, name|
        [ "--mount", "type=volume,src=#{name},dst=/measure/#{key},readonly" ]
      end
      @helper_name = "admin-storage-#{SecureRandom.hex(10)}"
      result = capture(
        "run", "--rm", "--name", @helper_name, "--network", "none", "--read-only",
        "--memory", "64m", "--cpus", "0.25", "--pids-limit", "32", *mounts,
        "busybox:1.37", "timeout", "60", "du", "-sk", *existing.keys.map { |key| "/measure/#{key}" }
      )
      raise MeasurementError unless result[:ok]

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
        measured_at: Time.current.iso8601, checked_at: Time.current.iso8601
      }
    rescue Agents::Resources::OwnershipError, MeasurementError, Timeout::Error, SystemCallError, KeyError
      # Preserve the last reading, but never present it as a successful refresh.
      @agent.storage_usage.merge("status" => "unavailable", "checked_at" => Time.current.iso8601)
    ensure
      remove_helper if @helper_name
    end

    private

    def remove_helper
      capture("rm", "-f", @helper_name)
    rescue Timeout::Error, SystemCallError
      # The helper also has an internal timeout and --rm. A daemon outage
      # must not turn an unavailable measurement into a failed admin job.
      nil
    end

    def capture(*args)
      Agents::Resources.new(@agent).verify_existing!
      Open3.popen3("docker", *args, pgroup: true) do |stdin, stdout, stderr, process|
        stdin.close
        output = Thread.new { stdout.read }
        errors = Thread.new { stderr.read }
        begin
          Timeout.timeout(90) do
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

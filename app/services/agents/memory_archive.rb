require "open3"
require "timeout"

module Agents
  class MemoryArchive
    class ReadError < StandardError; end

    def initialize(agent)
      @agent = agent
    end

    def overview = snapshot("overview")
    def catalog = snapshot("catalog")

    def bodies(items)
      return {} if items.empty?
      read("bodies", items: items)
    rescue ReadError
      items.to_h { |item| [ item.fetch("id"), { "body_status" => "unavailable" } ] }
    end

    private

    def snapshot(mode)
      Rails.cache.fetch([ "resident-memory-v1", @agent.id, @agent.uuid, @agent.container_name, mode ], expires_in: 2.minutes) do
        read(mode).merge("measured_at" => Time.current.iso8601)
      end
    rescue ReadError
      { "status" => "unavailable", "count" => nil, "daily_counts" => {}, "items" => [] }
    end

    def read(mode, **arguments)
      raise ReadError if @agent.container_name.blank?
      raise ReadError if @agent.sandbox_host.present? && @agent.sandbox_host != Config.sandbox_host
      Agents::Resources.new(@agent).verify_existing!
      script = Rails.root.join("app/services/agents/memory_archive.py").read
      JSON.parse(capture(script, { mode: mode, **arguments }.to_json))
    rescue Agents::Resources::OwnershipError, Timeout::Error, SystemCallError, JSON::ParserError
      raise ReadError
    end

    def capture(script, request)
      Open3.popen3("docker", "exec", "-i", @agent.container_name,
        "timeout", "25", "python3", "-c", script, pgroup: true) do |stdin, stdout, stderr, process|
        output = Thread.new { stdout.read(16.megabytes + 1) }
        errors = Thread.new { stderr.read(64.kilobytes) }
        begin
          Timeout.timeout(30) do
            stdin.write(request)
            stdin.close
            result = output.value
            raise ReadError if result.bytesize > 16.megabytes
            raise ReadError unless process.value.success?
            result
          end
        ensure
          stdin.close unless stdin.closed?
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

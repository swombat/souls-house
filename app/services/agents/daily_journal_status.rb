require "open3"

module Agents
  class DailyJournalStatus

    JOURNAL_DIR = "/home/agent/identity/memory/daily-journals".freeze

    attr_reader :agent

    def initialize(agent)
      @agent = agent
    end

    def snapshot
      return {} if agent.container_name.blank?

      result = docker_capture(
        "exec",
        agent.container_name,
        "sh",
        "-c",
        "find #{JOURNAL_DIR} -maxdepth 1 -type f -name '????-??-??.md' -exec wc -c {} \\; 2>/dev/null || true"
      )
      return {} unless result[:ok]

      result[:stdout].lines.each_with_object({}) do |line, hash|
        size, path = line.strip.split(/\s+/, 2)
        next if size.blank? || path.blank?

        hash[File.basename(path)] = size.to_i
      end
    end

    def grown_since?(before)
      after = snapshot
      after.any? do |path, size|
        before_size = before[path]
        before_size.nil? || size > before_size
      end
    end

    def entries?
      snapshot.any?
    end

    private

    def docker_capture(*args)
      Agents::Resources.new(agent).verify_existing!
      stdout, stderr, status = Open3.capture3("docker", *args)
      { stdout: stdout, stderr: stderr, ok: status.success? }
    end

  end
end

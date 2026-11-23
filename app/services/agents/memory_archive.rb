require "open3"
require "timeout"

module Agents
  class MemoryArchive
    class ReadError < StandardError; end

    # The journals layer is read by the same rule as the card's count
    # (journal_rule.py), so the tab and the card can't disagree about what an
    # entry is or where the journal lives.
    SCRIPT = (Agents::JournalEntryStats::RULE + "\n" +
              Rails.root.join("app/services/agents/memory_archive.py").read).freeze

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

    # The declaration is read fresh on every request, and the cache is keyed
    # by it: a home that says "journal": false is closed at once, even while
    # an older overview or catalog is still cached (Mira, #1113).
    def snapshot(mode)
      place, declared = current_place
      return { "status" => "not_shared", "count" => nil, "daily_counts" => {}, "items" => [] } if place.nil?

      # Declared or not is part of the key: the same missing folder is a
      # measured 0 by default but unavailable once declared (Mira, Reed, #1113).
      Rails.cache.fetch([ "resident-memory-v2", @agent.id, @agent.uuid, @agent.container_name, place, declared, mode ],
                        expires_in: 2.minutes) do
        read(mode).merge("measured_at" => Time.current.iso8601)
      end
    rescue ReadError
      { "status" => "unavailable", "count" => nil, "daily_counts" => {}, "items" => [] }
    end

    # The journal's place and whether the home declared it, or nil when it
    # is not shared.
    def current_place
      declared = read("declaration")
      return nil if declared["status"] == "not_shared"
      raise ReadError unless declared["status"] == "declared" && declared["place"].is_a?(String)

      [ declared["place"], declared["declared"] == true ]
    end

    def read(mode, **arguments)
      raise ReadError if @agent.container_name.blank?
      raise ReadError if @agent.sandbox_host.present? && @agent.sandbox_host != Config.sandbox_host
      Agents::Resources.new(@agent).verify_existing!
      JSON.parse(capture(SCRIPT, { mode: mode, journal_source: @agent.journal_source, **arguments }.to_json))
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

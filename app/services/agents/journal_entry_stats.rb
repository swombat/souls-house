require "open3"
require "timeout"

module Agents
  class JournalEntryStats

    class MeasurementError < StandardError; end

    # The card's number: entries in the journal the home declares, by the one
    # rule in journal_rule.py (Agents::MemoryArchive reads the same rule), or
    # "not shared". Only the aggregate leaves the resident's filesystem. Disk
    # use is measured apart, on a slower clock (Agents::HomeStorage): a walk of
    # a 100 GB home outlasted this script's budget, and the count should never
    # wait on it. The runner carries a byte-for-byte copy (HOME_STATS_SCRIPT).
    RULE = Rails.root.join("app/services/agents/journal_rule.py").read.freeze
    COUNT = <<~'PYTHON'

      # The count. argv[1], when present, is the file an admin chose
      # (Agent#journal_source), read only when the home declares nothing.
      import sys
      COUNT_FILE_MAX = 64 * 1024 * 1024
      def count_journal():
          home = os.open(HOME, DIRECTORY_FLAGS)
          try:
              try:
                  path, declared = journal_place(home, sys.argv[1] if len(sys.argv) > 1 else None)
              except NotShared:
                  return {"status": "not_shared"}
              count = 0
              try:
                  for document in documents(home, path, COUNT_FILE_MAX):
                      if document["data"] is None:
                          raise ValueError("a journal file could not be read")
                      count += len(entries(document))
              except FileNotFoundError:
                  if declared:
                      raise
                  count = 0
              return {"count": count}
          finally:
              os.close(home)
      print(json.dumps(count_journal()))
    PYTHON
    SCRIPT = (RULE + COUNT).freeze

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

      interpret(JSON.parse(result[:stdout]))
    rescue MeasurementError, Agents::Resources::OwnershipError, Timeout::Error,
           SystemCallError, JSON::ParserError
      @agent.journal_entry_stats.merge("status" => "unavailable")
    end

    private

    # A resident on its own server (#246): the same script, run by its runner.
    def remote
      interpret(Agents::RemoteRuntime.home_stats!(@agent))
    rescue MeasurementError, Agents::RemoteRuntime::Unavailable
      @agent.journal_entry_stats.merge("status" => "unavailable")
    end

    # A measured number, or "not shared" when the home says its journal is
    # not for the house to count. Anything else is a failed measurement.
    def interpret(measurement)
      raise MeasurementError unless measurement.is_a?(Hash)
      return { status: "not_shared", measured_at: Time.current.iso8601 } if measurement["status"] == "not_shared"

      count = measurement["count"]
      raise MeasurementError unless count.is_a?(Integer) && count >= 0

      { status: "measured", count: count, measured_at: Time.current.iso8601 }
    end

    def capture
      # The chosen journal goes in as one argv value, never into the code.
      ResidentPython.run(@agent.container_name, SCRIPT, *@agent.journal_source, seconds: 30)
    end

  end
end

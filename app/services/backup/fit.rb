module Backup
  # Keeps a resident's backup repository within its space (Backup::Space) by
  # thinning older history, and records what the repository holds.
  #
  # Runs after the routine thinning to the keep rules. While the repository
  # stores more than the resident's space and more than one backup is left, it
  # halves the number kept, newest first, and reads the result back. It never
  # removes the newest backup, and it never refuses one: a newest backup that
  # alone is larger than the space is the house's problem (Daniel: "that's a
  # problem on us rather than on the user"), recorded as over_space and
  # logged for site admins.
  #
  # `run` is restic for this resident's repository: called with restic's
  # arguments, returns its stdout, raises on failure.
  class Fit

    class Failed < StandardError; end

    STILL_TIGHT = 0.8

    def initialize(agent, run:, now: Time.current)
      @agent = agent
      @run = run
      @now = now
    end

    def call
      space = Space.bytes_for(@agent)
      kept = snapshots
      stored = stored_bytes
      thinned = false
      while stored > space && kept.size > 1
        @run.call("forget", "--group-by", "", "--keep-last", (kept.size / 2).to_s, "--prune")
        left = snapshots
        # A round that removed nothing, or everything, must not loop or pass.
        raise Failed, "No backup is left after thinning to fit" if left.empty?
        break if left.size >= kept.size

        kept = left
        stored = stored_bytes
        thinned = true
      end

      over = stored > space
      Rails.logger.error("[backup] over_space agent_id=#{@agent.id} stored_bytes=#{stored} space_bytes=#{space} snapshots=#{kept.size}") if over
      # Thinning to fit stays said while the repository is still near its space:
      # an owner should not see it flicker off on a night that needed no round.
      thinned ||= @agent.backup_history["thinned_to_fit"] == true && stored > space * STILL_TIGHT
      @agent.update!(backup_history: {
        "snapshots" => kept.size,
        "oldest_at" => kept.filter_map { |snapshot| parse_time(snapshot["time"]) }.min&.iso8601,
        "stored_bytes" => stored, "thinned_to_fit" => thinned, "over_space" => over,
        "read_at" => @now.iso8601
      })
      @agent.backup_history
    end

    private

    def snapshots
      list = JSON.parse(@run.call("snapshots", "--json"))
      raise Failed, "Unreadable snapshot list" unless list.is_a?(Array)

      list
    rescue JSON::ParserError
      raise Failed, "Unreadable snapshot list", cause: nil
    end

    # What the repository stores: deduplicated, compressed, every snapshot.
    def stored_bytes
      stats = JSON.parse(@run.call("stats", "--mode", "raw-data", "--json"))
      Integer(stats.fetch("total_size"))
    rescue JSON::ParserError, KeyError, TypeError, ArgumentError
      raise Failed, "Unreadable repository size", cause: nil
    end

    def parse_time(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end

  end
end

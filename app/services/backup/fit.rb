module Backup
  # Keeps a resident's backup repository within its space (Backup::Space) by
  # removing older history, and records what the repository holds.
  #
  # Runs after the routine thinning to the keep rules. While the backups kept
  # reference more than the resident's space and more than one is left, it
  # forgets the single oldest and measures again, so a resident a little over
  # loses one backup, not half of them. It never removes the newest backup,
  # and it never refuses one: a newest backup that alone is larger than the
  # space is the house's problem (Daniel: "that's a problem on us rather than
  # on the user"), recorded as over_space and reported to the site admins.
  #
  # A resident whose backups are never removed (Agent#backup_never_removed)
  # is measured and recorded the same way, and nothing of its history is
  # forgotten however far past its space it is.
  #
  # Two sizes. `referenced` is what the kept backups need (restic stats
  # --mode raw-data): it falls as soon as a backup is forgotten, so it decides
  # how much history goes. `physical` is every object in the repository, the
  # number the VM write ceiling counts; it also holds data no backup
  # references (a failed backup's partial upload) and falls only when a prune
  # runs. Fit prunes whenever it forgot something or the repository occupies
  # more than its space, and what it records as stored is the physical size
  # where one can be read.
  #
  # `run` is restic for this resident's repository: called with restic's
  # arguments, returns its stdout, raises on failure. `physical` returns the
  # repository's size in storage, or nil where that can't be asked. `before`
  # is the snapshot list read before a thinning began (Backup::VmThinning);
  # given it, the history also records how many of those backups are gone
  # (thinning_removed), counted by id against what is left, so a backup the
  # thinning did not actually remove is never counted.
  class Fit

    class Failed < StandardError; end
    class OverSpace < StandardError; end

    STILL_TIGHT = 0.8

    def initialize(agent, run:, physical: -> { Space.physical_bytes(agent) }, now: Time.current, before: nil)
      @agent = agent
      @before = before
      @run = run
      @physical = physical
      @now = now
    end

    def call
      space = Space.bytes_for(@agent)
      kept = snapshots
      referenced = referenced_bytes
      forgot = false
      while referenced > space && kept.size > 1 && !@agent.backup_never_removed?
        @run.call("forget", kept.first.fetch("id"))
        left = snapshots
        raise Failed, "No backup is left after thinning to fit" if left.empty?
        # A round that removed nothing must not loop.
        break if left.size >= kept.size

        kept = left
        referenced = referenced_bytes
        forgot = true
      end

      occupied = @physical.call
      if forgot || (occupied && occupied > space)
        @run.call("prune")
        occupied = @physical.call
      end
      stored = occupied || referenced

      # Only the newest backup is left and it alone does not fit.
      over = kept.size == 1 && referenced > space
      report_over_space(referenced, space) if over
      # Said while history is being cut to fit, and while the repository is
      # still near its space, so it does not flicker off on a quiet night.
      thinned = !@agent.backup_never_removed? && (forgot || (referenced > space && !over) ||
        (@agent.backup_history["thinned_to_fit"] == true && stored > space * STILL_TIGHT))
      history = {
        "snapshots" => kept.size, "oldest_at" => kept.first && parse_time(kept.first["time"])&.iso8601,
        "stored_bytes" => stored, "referenced_bytes" => referenced,
        "thinned_to_fit" => thinned, "over_space" => over, "read_at" => @now.iso8601
      }
      history["thinning_removed"] = removed_count(kept) if @before
      @agent.update!(backup_history: history)
      @agent.backup_history
    end

    private

    def removed_count(kept)
      left = kept.map { |snapshot| snapshot["id"] }
      @before.count { |snapshot| snapshot.is_a?(Hash) && snapshot["id"].present? && left.exclude?(snapshot["id"]) }
    end

    # Oldest first.
    def snapshots
      list = JSON.parse(@run.call("snapshots", "--json"))
      raise Failed, "Unreadable snapshot list" unless list.is_a?(Array) && list.all? { |item| item.is_a?(Hash) && item["id"].present? }

      list.sort_by { |snapshot| parse_time(snapshot["time"]) || Time.zone.at(0) }
    rescue JSON::ParserError
      raise Failed, "Unreadable snapshot list", cause: nil
    end

    def referenced_bytes
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

    # An alert, not only a log line: one per resident, to whoever watches the
    # house's errors.
    def report_over_space(referenced, space)
      Rails.logger.error("[backup] over_space agent_id=#{@agent.id} referenced_bytes=#{referenced} space_bytes=#{space}")
      Honeybadger.notify(OverSpace.new("A resident's newest backup alone is larger than its backup space"),
        context: { agent_id: @agent.id, referenced_bytes: referenced, space_bytes: space },
        fingerprint: "backup-over-space-#{@agent.id}")
    end

  end
end

module Agents
  # A resident's consecutive failed conversation runs, newest first, back to
  # the last completed run of any kind: a completed wake or rhythm run shows
  # the runtime works, so it ends the streak too. Busy, lost, cancelled and
  # non-conversation failed runs are paged past: they neither count nor end
  # it. A streak is a count and a start time, not a diagnosis.
  #
  # The scan is bounded. If it stops before reaching a completed run or the
  # start of the resident's history, the result is truncated: the count is a
  # lower bound, and there is no start time and no claim about the whole
  # streak's category.
  class RunFailureStreak

    BATCH = 200
    MAX_SCAN = 2_000

    Result = Data.define(:count, :since, :categories, :truncated) do
      def self.none = new(count: 0, since: nil, categories: [], truncated: false)

      # Only when every failure in a complete streak was a runtime that
      # couldn't be reached may the card say the runtime isn't starting.
      def runtime_unavailable?
        !truncated && count.positive? && categories.all?("runtime_unavailable")
      end

      def as_card_json
        return if count < 2

        { count: count, since: (since&.iso8601 unless truncated), runtime_unavailable: runtime_unavailable?, capped: truncated }
      end
    end

    # through: reads the streak as it stood when that run finished.
    def self.call(agent, through: nil, batch: BATCH, max_scan: MAX_SCAN)
      scope = agent.agent_runtime_interactions.where.not(finished_at: nil)
      scope = scope.where("(finished_at, id) <= (?, ?)", through.finished_at, through.id) if through
      failures = []
      scanned = 0
      cursor = nil
      bounded = false
      loop do
        page = cursor ? scope.where("(finished_at, id) < (?, ?)", *cursor) : scope
        rows = page.order(finished_at: :desc, id: :desc).limit(batch).to_a
        rows.each do |run|
          case run.streak_outcome
          when :success
            bounded = true
            break
          when :failure
            failures << run if run.trigger_kind == "conversation"
          end
        end
        # Fewer rows than asked for means the start of history was reached.
        bounded ||= rows.size < batch
        break if bounded

        scanned += rows.size
        break if scanned >= max_scan

        cursor = [ rows.last.finished_at, rows.last.id ]
      end
      truncated = !bounded
      Result.new(
        count: failures.size, since: (failures.last&.started_at unless truncated),
        categories: failures.map(&:failure_category), truncated: truncated
      )
    end

  end
end

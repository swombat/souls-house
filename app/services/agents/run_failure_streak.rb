module Agents
  # A resident's consecutive failed runs of one kind, newest first.
  #
  # kind: :conversation (the default) counts failed conversation runs back to
  # the last completed run of any kind: a completed wake or rhythm run shows
  # the runtime works, so it ends the streak too. Busy, lost, cancelled and
  # non-conversation failed runs are paged past: they neither count nor end it.
  #
  # kind: :scheduled counts failed wake and memory-aggregation runs back to
  # the last completed run of those kinds. A completed conversation run does
  # not end it: a resident can answer in rooms while every wake fails, and
  # that is the streak worth telling the owner about.
  #
  # A streak is a count and a start time, not a diagnosis.
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

      # Every failure in the streak was the provider refusing the model, so
      # the card can say why instead of only counting.
      def model_unavailable?
        !truncated && count.positive? && categories.all?("model_unavailable")
      end

      def as_card_json
        return if count < 2

        {
          count: count, since: (since&.iso8601 unless truncated), runtime_unavailable: runtime_unavailable?,
          model_unavailable: model_unavailable?, capped: truncated
        }
      end
    end

    # through: reads the streak as it stood when that run finished.
    def self.call(agent, through: nil, kind: :conversation, batch: BATCH, max_scan: MAX_SCAN)
      counts = kind == :scheduled ? ->(run) { run.scheduled_run? } : ->(run) { run.trigger_kind == "conversation" }
      ends = kind == :scheduled ? ->(run) { run.scheduled_run? } : ->(_run) { true }
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
            if ends.call(run)
              bounded = true
              break
            end
          when :failure
            failures << run if counts.call(run)
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

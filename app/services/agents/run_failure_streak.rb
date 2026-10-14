module Agents
  # A resident's consecutive failed conversation runs, newest first, back to
  # the last completed one. Busy, lost and cancelled runs are skipped: they
  # neither count nor end a streak. A streak is a count and a start time, not
  # a diagnosis; each failure keeps its own category.
  class RunFailureStreak

    LOOKBACK = 100

    Result = Data.define(:count, :since, :categories) do
      def self.none = new(count: 0, since: nil, categories: [])

      # Only when every failure in the streak was a runtime that couldn't be
      # reached is the card allowed to say the runtime isn't starting.
      def runtime_unavailable?
        count.positive? && categories.all?("runtime_unavailable")
      end

      def as_card_json
        return if count < 2

        { count: count, since: since&.iso8601, runtime_unavailable: runtime_unavailable?, capped: count >= LOOKBACK }
      end
    end

    # through: reads the streak as it stood when that run finished.
    def self.call(agent, through: nil)
      scope = agent.agent_runtime_interactions.where(trigger_kind: "conversation").where.not(finished_at: nil)
      if through
        scope = scope.where("(finished_at, id) <= (?, ?)", through.finished_at, through.id)
      end
      failures = []
      scope.order(finished_at: :desc, id: :desc).limit(LOOKBACK).each do |run|
        case run.streak_outcome
        when :failure then failures << run
        when :success then break
        end
      end
      Result.new(count: failures.size, since: failures.last&.started_at, categories: failures.map(&:failure_category))
    end

  end
end

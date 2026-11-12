class ExternalAgentMemoryAggregationJob < ApplicationJob

  # Residents used to start back to back within seconds; at 02:00Z on
  # 12 Nov that refused connections on the shared Postgres (#915). Each
  # resident now gets a stable offset inside this window.
  SPREAD = 20.minutes

  queue_as :default

  def self.offset_for(agent)
    (Zlib.crc32("memory-aggregation-#{agent.id}") % SPREAD.to_i).seconds
  end

  def self.aggregatable_agents
    Agent.active
         .unpaused
         .not_billing_held
         .where(runtime: "external")
         .where.not(trigger_bearer_token: [ nil, "" ])
  end

  # The recurring entry passes only the period. That run freezes the target
  # from its own original enqueue time (kept on the job row across Solid
  # Queue retries, not the clock) and re-enqueues itself with it, so no
  # retry can move the day. The frozen run only fans out; a retried fan-out
  # re-enqueues children and the child's key makes that harmless.
  def perform(period, target = nil)
    period = period.to_s
    if target.nil?
      self.class.perform_later(period, default_target_for(period, anchor: enqueued_at || Time.current))
      return
    end

    self.class.aggregatable_agents.find_each do |agent|
      ExternalAgentMemoryAggregationAgentJob
        .set(wait: self.class.offset_for(agent))
        .perform_later(agent.id, period, target)
    end
  end

  private

  def default_target_for(period, anchor: Time.current)
    anchor = anchor.in_time_zone
    case period
    when "daily"
      (anchor - 1.day).to_date.iso8601
    when "weekly"
      (anchor - 1.week).to_date.beginning_of_week.iso8601
    when "monthly"
      (anchor - 1.month).to_date.strftime("%Y-%m")
    else
      raise ArgumentError, "unknown memory aggregation period: #{period}"
    end
  end

end

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

  # Fans out only: the target is frozen here and passed to every child, so a
  # run delayed past midnight still aggregates the day it was scheduled for.
  # A retried parent re-enqueues; the child's key makes that harmless.
  def perform(period, target = nil)
    period = period.to_s
    target ||= default_target_for(period)

    self.class.aggregatable_agents.find_each do |agent|
      ExternalAgentMemoryAggregationAgentJob
        .set(wait: self.class.offset_for(agent))
        .perform_later(agent.id, period, target)
    end
  end

  private

  def default_target_for(period)
    case period
    when "daily"
      1.day.ago.to_date.iso8601
    when "weekly"
      1.week.ago.to_date.beginning_of_week.iso8601
    when "monthly"
      1.month.ago.to_date.strftime("%Y-%m")
    else
      raise ArgumentError, "unknown memory aggregation period: #{period}"
    end
  end

end

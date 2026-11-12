# One resident's aggregation for one frozen target, enqueued with a stable
# offset by ExternalAgentMemoryAggregationJob.
class ExternalAgentMemoryAggregationAgentJob < ApplicationJob

  queue_as :default

  limits_concurrency to: 1,
    key: ->(agent_id, period, target) { "memory-aggregation-#{agent_id}-#{period}-#{target}" },
    duration: 3.hours

  def perform(agent_id, period, target)
    # Eligibility is read when the run fires, not when it was enqueued.
    agent = ExternalAgentMemoryAggregationJob.aggregatable_agents.find_by(id: agent_id)
    return unless agent
    return if ExternalAgentMemoryAggregationRequest.accepted?(agent: agent, period: period, target: target)

    ExternalAgentMemoryAggregationRequest.new(agent: agent, period: period, target: target).call
  end

end

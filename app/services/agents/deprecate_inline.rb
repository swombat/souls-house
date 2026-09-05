module Agents
  # Deliberate data transition, never a boot hook or a recurring job.
  class DeprecateInline

    class InventoryChanged < StandardError; end
    REASON = "The Rails inline agent runtime has been retired."
    HARNESS_ATTRIBUTES = %w[container_name endpoint_url outbound_api_key_id birth_committed_at].freeze

    def self.inventory
      Agent.where(runtime: %w[inline migrating deprecated]).order(:id).map do |agent|
        {
          id: agent.id, runtime: agent.runtime, updated_at: agent.updated_at.iso8601(6),
          harness_metadata: HARNESS_ATTRIBUTES.select { |attribute| agent[attribute].present? }
        }
      end
    end

    def self.call(expected_ids:)
      ids = expected_ids.map { |id| Integer(id) }.uniq.sort
      raise ArgumentError, "An explicit nonempty list of reviewed agent IDs is required" if ids.empty?

      Agent.transaction do
        # Lock candidate rows; application admission already rejects legacy values.
        candidates = Agent.where(runtime: %w[inline migrating]).or(Agent.where(id: ids)).order(:id).lock.to_a
        if candidates.any?(&:migrating?)
          raise InventoryChanged, "Resolve all migrating agents before deprecation"
        end
        unless candidates.map(&:id) == ids && candidates.all? { |agent| agent.runtime.in?(%w[inline deprecated]) }
          raise InventoryChanged, "Inline inventory changed or a reviewed ID now has a harness"
        end
        if candidates.any? { |agent| HARNESS_ATTRIBUTES.any? { |attribute| agent[attribute].present? } }
          raise InventoryChanged, "Reviewed agents have harness metadata; resolve it explicitly"
        end

        now = Time.current
        candidates.each do |agent|
          agent.update!(
            runtime: "deprecated",
            deprecated_at: agent.deprecated_at || now,
            deprecation_reason: agent.deprecation_reason.presence || REASON,
            trigger_bearer_token: nil
          )
        end
        ids
      end
    end

  end
end

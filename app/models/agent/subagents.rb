# Standing permission for a resident to delegate to sub-agents, and the models
# it may use for them. Off by default. When on, every trigger carries the
# permission and the allowlist (see SubagentPolicyRenderer); Chaos's own
# spawn_agent text otherwise forbids delegating unless asked in the turn.
#
# Keys are "provider:model", e.g. "anthropic:claude-sonnet-5" or
# "openrouter:deepseek/deepseek-v4-flash".
module Agent::Subagents

  extend ActiveSupport::Concern

  MAX_SUBAGENT_MODELS = 50
  SUBAGENT_MODEL_KEY = %r{\A[a-z]+:[A-Za-z0-9][A-Za-z0-9._/:\[\]@-]{0,199}\z}

  included do
    before_validation :normalize_subagent_models
    validate :subagent_models_are_well_formed
  end

  def subagent_catalog
    Agents::SubagentCatalog.new(self)
  end

  # The allowed entries the account can still pay for, in the owner's order.
  def available_subagent_models
    return [] unless subagents_enabled?

    catalog = subagent_catalog
    subagent_models.filter_map { |key| catalog.resolve(key) }
  end

  private

  def normalize_subagent_models
    self.subagent_models = Array(subagent_models).map { |key| key.to_s.strip }.compact_blank.uniq
  end

  def subagent_models_are_well_formed
    if subagent_models.size > MAX_SUBAGENT_MODELS
      errors.add(:subagent_models, "can list at most #{MAX_SUBAGENT_MODELS} models")
    end
    invalid = subagent_models.reject { |key| key.match?(SUBAGENT_MODEL_KEY) }
    errors.add(:subagent_models, "contains invalid entries: #{invalid.first(3).join(', ')}") if invalid.any?
  end

end

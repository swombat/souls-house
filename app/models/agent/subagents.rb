# Standing permission for a resident to delegate to sub-agents, and the models
# it may use for them. Off by default. When on, every trigger carries the
# permission and the allowlist (see SubagentPolicyRenderer); Chaos's own
# spawn_agent text otherwise forbids delegating unless asked in the turn.
#
# Keys are "provider:model", e.g. "anthropic:claude-sonnet-5" or
# "openrouter:deepseek/deepseek-v4-flash".
#
# Sub-agents come with the account's plan (Billing::AccountPlan, Colleagues),
# not the resident's size (2026-11-10). A resident of a Colleagues account has
# them while its own entitlement is in force (active, grace or complimentary),
# or when it has no entitlement and no birth order (on the house). A paid
# birth has no entitlement for a moment (between the birth committing and
# billing linking it, retried until it succeeds), so a resident with a birth
# order is never taken for one on the house. Other plans can't switch it on,
# and a resident whose account drops below Colleagues, or whose own plan
# lapses, stops carrying the permission even if the switch was left on.
module Agent::Subagents

  extend ActiveSupport::Concern

  MAX_SUBAGENT_MODELS = 50
  SUBAGENT_MODEL_KEY = %r{\A[a-z]+:[A-Za-z0-9][A-Za-z0-9._/:\[\]@-]{0,199}\z}

  included do
    before_validation :normalize_subagent_models
    before_save :stamp_subagent_policy_change, if: -> { subagents_enabled_changed? || subagent_models_changed? }
    validate :subagent_models_are_well_formed
    validate :subagents_allowed_by_plan, if: -> { subagents_enabled? && subagents_enabled_changed? }
  end

  def subagent_catalog
    Agents::SubagentCatalog.new(self)
  end

  # Whether this resident may use sub-agents: its account's plan includes
  # them and its own hosting is in force.
  def subagents_available?
    return false unless account&.plan&.subagents?

    entitlement = ResidentEntitlement.find_by(agent_id: id)
    return !ResidentBirthOrder.exists?(agent_id: id) if entitlement.nil?

    entitlement.state.in?(Billing::Tier::IN_FORCE_STATES)
  end

  # The switch is on and the plan allows it.
  def subagents_permitted?
    subagents_enabled? && subagents_available?
  end

  # The allowed entries the account can still pay for, in the owner's order.
  def available_subagent_models
    return [] unless subagents_permitted?

    catalog = subagent_catalog
    subagent_models.filter_map { |key| catalog.resolve(key) }
  end

  private

  # Once a policy has been set, triggers keep stating the current one, so that
  # switching it off reaches sessions that saw the earlier permission.
  def stamp_subagent_policy_change
    self.subagents_policy_changed_at = Time.current
  end

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

  def subagents_allowed_by_plan
    errors.add(:subagents_enabled, "Sub-agents come with the Colleagues plan") unless subagents_available?
  end

end

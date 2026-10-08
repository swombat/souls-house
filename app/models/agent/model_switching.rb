# Which models a resident may run on in a single conversation, chosen by the
# account. The resident's `model_id` stays its default; a conversation seat
# (ChatAgent#model_id) may select one of these instead. Selection never fires
# the account-wide model-change notice or an orientation wake: those stay keyed
# to `model_id`.
#
# A switchable model must be a catalogue model with a provider route and the
# same provider family as the default, so the auth mode, clamp setting and
# subscription stay the same across a switch, and the runtime keeps the same
# Chaos session. House offerings are excluded.
module Agent::ModelSwitching

  extend ActiveSupport::Concern

  MAX_SWITCHABLE_MODELS = 8

  included do
    before_validation :normalize_switchable_model_ids
    validate :switchable_model_ids_are_valid
  end

  # The default first, then the allowlist, as [{ model_id:, label: }].
  def model_choices
    ([ model_id ] + valid_switchable_model_ids).uniq.map do |id|
      { model_id: id, label: self.class.label_for_model(id) }
    end
  end

  def model_switching_available?
    model_choices.size > 1
  end

  # Why `candidate` cannot be selected in a conversation now, or nil.
  def model_selection_problem(candidate)
    candidate = candidate.to_s
    return if candidate == model_id
    return "is not on #{name}'s list of models for conversations" unless switchable_model_ids.include?(candidate)

    self.class.switchable_model_problem(candidate, default_model_id: model_id)
  end

  def valid_switchable_model_ids
    switchable_model_ids.select { |id| self.class.switchable_model_problem(id, default_model_id: model_id).nil? }
  end

  class_methods do
    def label_for_model(id)
      Chat.model_config(id.to_s)&.dig(:label) || id.to_s
    end

    def model_family(id)
      id.to_s[%r{\A([^/]+)/}, 1]
    end

    def switchable_model_problem(candidate, default_model_id:)
      return "is a house model and cannot be selected per conversation" if HouseInference::Offering.find(candidate)
      return "is not in the model catalogue" unless Chat.model_config(candidate)&.dig(:provider_model_id)
      if HouseInference::Offering.find(default_model_id)
        return "cannot be used while the default model is a house model"
      end
      unless model_family(candidate) == model_family(default_model_id)
        return "is from a different provider than the default model"
      end

      nil
    end
  end

  private

  def normalize_switchable_model_ids
    self.switchable_model_ids = Array(switchable_model_ids).map { |id| id.to_s.strip }.compact_blank.uniq - [ model_id ]
  end

  def switchable_model_ids_are_valid
    if switchable_model_ids.size > MAX_SWITCHABLE_MODELS
      errors.add(:switchable_model_ids, "can list at most #{MAX_SWITCHABLE_MODELS} models")
    end
    # Only newly listed entries are refused: a later change of default model
    # must not make an unrelated save fail. Stale entries are reported when a
    # conversation tries to use them.
    added = switchable_model_ids - Array(switchable_model_ids_was)
    added.each do |id|
      problem = self.class.switchable_model_problem(id, default_model_id: model_id)
      errors.add(:switchable_model_ids, "#{self.class.label_for_model(id)} #{problem}") if problem
    end
  end

end

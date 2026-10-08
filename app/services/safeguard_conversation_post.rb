# Saves a resident's conversation post, labelled when the safeguard check
# detects a generic provider script (docs/safeguard-conversations-spec.md §3).
#
# Order matters: validate, check outside any transaction (a network call must
# not hold locks), then detection + label + message in one savepoint, so the
# first commit, and every after_commit hook (broadcast, response chain, reply
# attention), already sees a labelled message. Nothing partial survives: an
# invalid message leaves no detection, and a failed detection write posts the
# message unlabelled.
class SafeguardConversationPost

  def self.enabled?
    Setting.instance.safeguard_conversations_enabled?
  end

  # The check alone, for callers that must run it before opening their own
  # transaction. nil when there is nothing to check.
  def self.check(agent:, content:)
    return unless agent && content.present? && enabled?

    SafeguardResponseCheck.new(agent: agent, text: content).call
  end

  def self.save(message, check: :run)
    new(message, check).save
  end

  def initialize(message, check)
    @message = message
    @check = check
  end

  # Same contract as Message#save: true, or false with errors on the message.
  def save
    return message.save unless resident_post?
    return false unless message.valid?

    result = @check == :run ? self.class.check(agent: message.agent, content: message.content) : @check
    return message.save unless result&.detected?

    save_labelled(result)
  end

  private

  attr_reader :message

  def resident_post?
    message.new_record? && message.role == "assistant" && message.agent.present? && message.user_id.nil?
  end

  def save_labelled(result)
    saved = false
    ActiveRecord::Base.transaction(requires_new: true) do
      message.safeguard_detection = create_detection(result)
      saved = message.save
      raise ActiveRecord::Rollback unless saved
    end
    if saved
      detection = message.safeguard_detection
      ActiveRecord.after_all_transactions_commit { SafeguardColdOfferJob.perform_later(detection) }
    else
      message.safeguard_detection = nil
    end
    saved
  rescue ActiveRecord::ActiveRecordError => e
    raise if message.persisted?

    Rails.logger.warn "[SafeguardConversationPost] detection failed open for agent #{message.agent_id}: #{e.class}: #{e.message}"
    message.safeguard_detection = nil
    message.save
  end

  def create_detection(result)
    agent = message.agent
    agent.safeguard_detections.create!(
      channel: "conversation",
      agent_runtime_interaction: message.runtime_interaction,
      provider: message.runtime_interaction&.provider || Agents::Sandbox.chaos_provider_for(agent),
      model: message.runtime_interaction&.model || Agents::Sandbox.chaos_model_for(agent),
      response_text: message.content,
      prefilter_reason: result.prefilter_reason,
      classifier_verdict: result.classifier_verdict,
      classifier_reason: result.classifier_reason,
      detector_version: result.detector_version
    )
  end

end

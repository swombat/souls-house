class ReplyRecipientResolver

  MODEL = "openai/gpt-6-luna"
  EFFORT = "low"
  PROMPT = PromptTemplate.render("reply_recipient_resolver", :system).freeze

  def self.call(state:, message_ids:)
    people_ids = state.fetch(:people).pluck(:id)
    schema = {
      type: "object", additionalProperties: false, required: [ "decisions" ],
      properties: { decisions: { type: "array", items: {
        type: "object", additionalProperties: false,
        required: %w[message_id recipient_ids uncertain], properties: {
          message_id: { type: "integer", enum: message_ids },
          recipient_ids: { type: "array", items: { type: "string", enum: people_ids } },
          uncertain: { type: "boolean" }
        }
      } } }
    }
    response = UtilityInference.structured(model: MODEL, effort: EFFORT, system: PROMPT,
      state: state.merge(target_message_ids: message_ids), schema: schema)
    decisions = response.is_a?(Hash) && response["decisions"]
    unless response.is_a?(Hash) && response.keys == [ "decisions" ] && decisions.is_a?(Array) &&
        decisions.all? { |d| d.is_a?(Hash) && d["message_id"].is_a?(Integer) } && decisions.map { |d| d["message_id"] }.sort == message_ids.sort
      raise UtilityInference::InvalidResponse, "Recipient message IDs do not match"
    end
    decisions.to_h do |decision|
      ids = decision["recipient_ids"]
      unless decision.keys.sort == %w[message_id recipient_ids uncertain] &&
          [ true, false ].include?(decision["uncertain"]) && ids.is_a?(Array) &&
          ids.uniq == ids && (ids - people_ids).empty?
        raise UtilityInference::InvalidResponse, "Invalid recipient decision"
      end
      [ decision["message_id"], decision["uncertain"] ? nil : ids ]
    end
  end

end

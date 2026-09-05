# Small, non-streaming calls owned by the house, not resident execution.
class UtilityInference

  class Error < StandardError; end
  class MissingCredentials < Error; end
  class InvalidResponse < Error; end
  class InputTooLong < Error; end

  MAX_INPUT_LENGTH = 32_000
  REQUEST_TIMEOUT = 20
  TITLE_MODEL = "google/gemini-2.5-flash"
  MODERATION_MODEL = "omni-moderation-latest"

  def self.title(account:, system:, user:, model: TITLE_MODEL)
    key = account.ai_api_key(:openrouter)
    return if key.blank? || key.start_with?("<")

    chat(key: key, model: model, system: system, user: user)
  end

  def self.classify(model:, prompt:)
    chat(
      key: Account.system_ai_api_key(:openrouter),
      model: model, user: prompt
    )
  end

  def self.moderate(content)
    validate_input!(content)
    response = client(key: Account.system_ai_api_key(:openai)).moderations(
      parameters: { model: MODERATION_MODEL, input: content }
    )
    scores = response.is_a?(Hash) && response.dig("results", 0, "category_scores")
    unless scores.is_a?(Hash) && scores.any? &&
        scores.values.all? { |score| score.is_a?(Numeric) && score.finite? && score.between?(0, 1) }
      raise InvalidResponse, "Invalid moderation scores"
    end

    scores
  end

  def self.chat(key:, model:, user:, system: nil)
    validate_input!("#{system}#{user}")
    messages = []
    messages << { role: "system", content: system } if system.present?
    messages << { role: "user", content: user }
    response = client(key: key, openrouter: true).chat(
      # OpenRouter's cap includes reasoning. These short utility calls need
      # visible output, not a thinking budget; exclude:true would only hide it.
      parameters: { model: model, messages: messages, max_tokens: 1_000, reasoning: { effort: "none" } }
    )
    content = response.is_a?(Hash) && response.dig("choices", 0, "message", "content")
    raise InvalidResponse, "Empty utility response" unless content.is_a?(String) && content.present?

    content
  end

  def self.client(key:, openrouter: false)
    raise MissingCredentials, "Utility inference credentials unavailable" if key.blank? || key.start_with?("<")

    OpenAI::Client.new(
      access_token: key,
      uri_base: openrouter ? "https://openrouter.ai/api/v1" : "https://api.openai.com/v1",
      request_timeout: REQUEST_TIMEOUT,
      log_errors: false
    )
  end

  def self.validate_input!(text)
    raise InputTooLong, "Utility input exceeds limit" if text.length > MAX_INPUT_LENGTH
  end

  private_class_method :chat, :client, :validate_input!

end

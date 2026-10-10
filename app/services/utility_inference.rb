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

  # Jev is a typed decision model, not a chat-completion model.
  def self.decide(state:, questions:)
    payload = { model: "typesafe/jev-1.13", state: state, questions: questions }.to_json
    validate_input!(payload)
    key = Account.system_ai_api_key(:openrouter)
    raise MissingCredentials, "Utility inference credentials unavailable" if key.blank? || key.start_with?("<")

    response = Faraday.post("https://openrouter.ai/api/alpha/decisions") do |request|
      request.headers["Authorization"] = "Bearer #{key}"
      request.headers["Content-Type"] = "application/json"
      request.options.timeout = REQUEST_TIMEOUT
      request.options.open_timeout = REQUEST_TIMEOUT
      request.body = payload
    end
    raise InvalidResponse, "Decision provider returned HTTP #{response.status}" unless response.success?

    result = JSON.parse(response.body)
    raise InvalidResponse, "Invalid decision response" unless result.is_a?(Hash)
    answers = result.fetch("answers")
    unless answers.is_a?(Hash) && answers.keys.sort == questions.keys.sort
      raise InvalidResponse, "Decision answer keys do not match questions"
    end
    answers.transform_values do |answer|
      score = answer.is_a?(Hash) && answer["noul"]
      unless answer.is_a?(Hash) && answer["type"] == "noul" && score.is_a?(Numeric) && score.finite? && score.between?(0, 1)
        raise InvalidResponse, "Invalid decision probability"
      end
      score
    end
  rescue Faraday::Error, JSON::ParserError, KeyError => error
    # Never include transport exception text: it can contain request bodies/keys.
    raise InvalidResponse, "Decision request failed (#{error.class})"
  end

  def self.structured(model:, effort:, system:, state:, schema:)
    parameters = {
      model: model, reasoning: { effort: effort }, max_tokens: 2_000,
      messages: [ { role: "system", content: system }, { role: "user", content: state.to_json } ],
      response_format: { type: "json_schema", json_schema: { name: "reply_recipients", strict: true, schema: schema } }
    }
    validate_input!(parameters.to_json)
    response = client(key: Account.system_ai_api_key(:openrouter), openrouter: true).chat(parameters: parameters)
    content = response.is_a?(Hash) && response.dig("choices", 0, "message", "content")
    raise InvalidResponse, "Empty structured response" unless content.is_a?(String) && content.present?

    JSON.parse(content)
  rescue Faraday::Error, JSON::ParserError, TypeError => error
    raise InvalidResponse, "Structured request failed (#{error.class})"
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

  # House-paid: the house inference key (HouseInference::Offering.key), pinned
  # to one provider with no fallback, as the on-the-house resident models are.
  # data_collection "deny" rules out providers that train on prompts; it does
  # not stop a provider retaining them (Anthropic: up to 30 days). Not metered
  # in the per-resident house ledger. Returns the text of the answer.
  def self.house_chat(model:, provider:, system:, user:, max_tokens: 400)
    validate_input!("#{system}#{user}")
    response = client(key: HouseInference::Offering.key, openrouter: true).chat(
      parameters: {
        model: model, max_tokens: max_tokens,
        messages: [ { role: "system", content: system }, { role: "user", content: user } ],
        provider: { only: [ provider ], allow_fallbacks: false, data_collection: "deny" }
      }
    )
    content = response.is_a?(Hash) && response.dig("choices", 0, "message", "content")
    raise InvalidResponse, "Empty house utility response" unless content.is_a?(String) && content.present?

    content
  rescue Faraday::Error => error
    # Never include transport exception text: it can contain request bodies/keys.
    raise InvalidResponse, "House utility request failed (#{error.class})"
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

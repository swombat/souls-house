# frozen_string_literal: true

# Shared logic for routing LLM calls to direct provider APIs when API keys are available.
# Falls back to OpenRouter for providers without configured keys (e.g., DeepSeek).
#
# Used to select the model/provider sent to the external harness.
module ResolvesProvider

  module_function

  def resolve_provider(model_id, account: nil)
    # Only route direct for models with an explicit provider_model_id mapping.
    # This ensures we only use model IDs known to work on direct provider APIs.
    # Models without a mapping (OpenRouter aliases, :thinking suffix, etc.) stay on OpenRouter.
    config = Chat.model_config(model_id)
    direct_model_id = config&.dig(:provider_model_id)
    return { provider: :openrouter, model_id: model_id } unless direct_model_id

    if model_id.start_with?("anthropic/") && api_key_available?(:anthropic, account: account)
      { provider: :anthropic, model_id: direct_model_id }
    elsif model_id.start_with?("openai/") && api_key_available?(:openai, account: account)
      { provider: :openai, model_id: direct_model_id }
    elsif model_id.start_with?("google/") && api_key_available?(:gemini, account: account)
      { provider: :gemini, model_id: direct_model_id }
    elsif model_id.start_with?("x-ai/") && api_key_available?(:xai, account: account)
      { provider: :xai, model_id: direct_model_id }
    else
      { provider: :openrouter, model_id: model_id }
    end
  end

  def api_key_available?(provider, account: nil)
    key = account&.ai_api_key(provider)
    return key.present? && !key.start_with?("<") if account

    key = Account.system_ai_api_key(provider)
    key.present? && !key.start_with?("<")
  end

end

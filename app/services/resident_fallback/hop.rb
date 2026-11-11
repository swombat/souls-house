# When a resident's subscription refuses a conversation turn before anything
# ran (the runtime's pre-dispatch 429, subscription_usage "limited"), the
# house may answer that turn on the owner's paid fallback instead (#690).
#
# Only that refusal hops: a run that failed part way with a limit keeps its
# readable failure. Only a conversation turn on a subscription, only on the
# subscription lane (a fallback turn never hops again), only while the Site
# Admin switch is on and the owner's policy would admit a call now.
#
# The hop opens a ResidentFallbackTurn linking the refused attempt to the
# fallback attempt and queues the fallback run. Returns the turn, or nil
# when the refusal stands as before.
module ResidentFallback
  class Hop

    def self.after_refusal(interaction:, result:)
      new(interaction, result).call
    end

    def self.pre_dispatch_limit?(result)
      result = result.to_h.with_indifferent_access
      body = result[:body]
      result[:status].to_i == 429 && body.is_a?(Hash) && body["error_kind"] == "subscription_limit" &&
        body.dig("subscription_usage", "status") == "limited"
    end

    def initialize(interaction, result)
      @interaction, @result = interaction, result
    end

    def call
      return unless eligible?

      policy = agent.fallback_policy
      turn = ResidentFallbackTurn.create!(
        agent: agent, chat: @interaction.chat, primary_interaction: @interaction,
        primary_provider: @interaction.provider, primary_model: @interaction.model,
        fallback_model_id: policy.model_id, upstream_model: policy.model_config.fetch(:upstream_model),
        primary_resets_at: resets_at
      )
      ResidentFallbackHopJob.set(wait: 1.second).perform_later(turn.id)
      turn
    rescue StandardError => e
      Rails.logger.warn("[ResidentFallback::Hop] #{agent&.id} not hopped: #{e.class}")
      nil
    end

    private

    def agent = @interaction.agent

    def eligible?
      return false unless self.class.pre_dispatch_limit?(@result)
      return false unless @interaction.trigger_kind == "conversation" && @interaction.chat
      return false unless @interaction.provider_auth_mode == "oauth_account"
      return false if Lane.fallback_session?(@interaction.session_id)
      return false if ResidentFallbackTurn.exists?(primary_interaction_id: @interaction.id)
      return false unless Setting.instance.paid_fallback_enabled?

      Decision.for(agent).ok?
    end

    def resets_at
      snapshot = @result.to_h.with_indifferent_access.dig(:body, "subscription_usage")
      AgentSubscriptionUsage.new(snapshot).resets_at if snapshot
    rescue StandardError
      nil
    end

  end
end

# When a resident's subscription refuses a conversation turn before anything
# ran (the runtime's pre-dispatch 429, subscription_usage "limited"), the
# house may answer that turn on the owner's paid fallback instead (#690).
#
# One logical turn stays one run (AgentRuntimeInteraction). The refused
# attempt is never recorded as the run's result: the same run, its claim
# already won, is dispatched again on the fallback lane. So everything that
# follows a run's outcome (a commitment's delivery, the response chain, a
# handoff, a released wake, the live card) follows the fallback's, and the
# request carries the same cues. Before the fallback dispatch, the source
# that authorised the run is asked again whether it would still allow it
# (source_refusal): nothing is consumed, and a refusal ends the run with the
# subscription's answer, as before the hop existed.
#
# Only that refusal hops: a run that failed part way with a limit keeps its
# readable failure. Only a conversation turn on a subscription, on the
# subscription lane (a fallback dispatch never hops again), once per run,
# never a new resident's greeting, while the Site Admin switch is on and the
# owner's policy would admit a call now.
module ResidentFallback
  class Hop

    def self.pre_dispatch_limit?(result)
      result = result.to_h.with_indifferent_access
      body = result[:body]
      result[:status].to_i == 429 && body.is_a?(Hash) && body["error_kind"] == "subscription_limit" &&
        body.dig("subscription_usage", "status") == "limited"
    end

    # Opens the hop for this run if it qualifies: the ResidentFallbackTurn
    # (the refused attempt's provider, model and response, and the model it
    # moves to). Returns it, or nil when the refusal stands.
    #
    # check_sources: false defers the source check to the fallback dispatch
    # (ResidentFallbackHopJob), for a caller holding locks the sources'
    # checks would take in another order.
    def self.open!(interaction:, result:, check_sources: true)
      new(interaction, result, check_sources:).open!
    end

    # Why the source that authorised this run would no longer start it, or
    # nil. Re-read now, under the sources' own locks, consuming nothing.
    def self.source_refusal(interaction)
      agent, chat = interaction.agent.reload, interaction.chat
      return "conversation_unavailable" unless chat&.reload&.respondable? && chat.manual_responses?
      return "not_in_room" unless chat.agent_seated_for_request?(agent.id, interaction.response_requested_at || interaction.created_at)
      if (dispatch = interaction.message_dispatch)
        reason = dispatch.with_lock { dispatch.source_invalid_reason }
        return "message_dispatch:#{reason}" if reason
      end
      if (wake = interaction.released_pending_wake)
        reason = wake.with_lock { wake.claim_refusal_reason }
        return "pending_wake:#{reason}" if reason
      end
      if (commitment = Commitment.find_by(wake_interaction_id: interaction.id))
        reason = commitment.with_lock { commitment.claim_refusal_reason }
        return "commitment:#{reason}" if reason
      end
      if interaction.stalled_thread_sweep_id && (reason = StalledThreadWake.refusal_reason(chat: chat, agent: agent))
        return "stalled_sweep:#{reason}"
      end
      handoffs = interaction.message_handoffs.order(:id).to_a
      if handoffs.any?
        reasons = MessageHandoff.transaction { handoffs.map(&:claim_refusal_reason) }
        return "handoff:#{reasons.first}" if reasons.none?(&:nil?)
      end
      return "paused" if agent.paused?

      nil
    end

    def initialize(interaction, result, check_sources: true)
      @interaction, @result, @check_sources = interaction, result, check_sources
    end

    def open!
      return unless eligible?

      policy = agent.fallback_policy
      ResidentFallbackTurn.create!(
        agent: agent, chat: @interaction.chat, primary_interaction: @interaction, fallback_interaction: @interaction,
        primary_provider: @interaction.provider, primary_model: @interaction.model,
        fallback_model_id: policy.model_id, upstream_model: policy.model_config.fetch(:upstream_model),
        primary_resets_at: resets_at, primary_result: @result.to_h.deep_stringify_keys
      )
    rescue StandardError => e
      Rails.logger.warn("[ResidentFallback::Hop] #{agent&.id} not hopped: #{e.class}")
      nil
    end

    private

    def agent = @interaction.agent

    def eligible?
      return false unless self.class.pre_dispatch_limit?(@result)
      return false unless @interaction.trigger_kind == "conversation" && @interaction.chat && @interaction.finished_at.nil?
      return false unless @interaction.provider_auth_mode == "oauth_account"
      return false if Lane.fallback_session?(@interaction.session_id)
      return false if ResidentFallbackTurn.exists?(primary_interaction_id: @interaction.id)
      return false if Agent.exists?(first_conversation_interaction_id: @interaction.id)
      # An imported home brings its own Chaos configuration, which may name a
      # provider with a key of its own; the runtime's guard only removes the
      # keys the house provides (#690). Not in v1.
      return false if agent.imported_home?
      return false unless Setting.instance.paid_fallback_enabled?
      return false unless Decision.for(agent).ok?

      !@check_sources || self.class.source_refusal(@interaction).nil?
    end

    def body_snapshot = @result.to_h.with_indifferent_access.dig(:body, "subscription_usage")

    def resets_at
      snapshot = body_snapshot
      AgentSubscriptionUsage.new(snapshot).resets_at if snapshot
    rescue StandardError
      nil
    end

  end
end

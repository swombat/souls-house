# The paid fallback's call boundary (#690 slice B). A resident whose
# subscription refused a turn before it started may answer on the model its
# owner chose, paid by the account's own OpenRouter key, one provider call at
# a time: each call is admitted only if its worst case fits in what is left
# of the owner's cap (Decision.admit_call!), and settles to the reported cost.
#
# It serves `fallback/<model>` only for a call made by an unfinished run that
# the house opened as a fallback turn (ResidentFallback::Hop), for the model
# that turn was opened on, while the Site Admin switch is on. Everything else
# about the call (bounded input, text and function tools only, pinned vendor,
# max_price, no provider fallbacks) is HouseInference's.
module ResidentFallback
  class Gateway < HouseInference::Gateway

    PREFIX = "fallback/".freeze

    def self.model_id_for(policy_model_id) = "#{PREFIX}#{policy_model_id}"

    def self.fallback_model?(model) = model.to_s.start_with?(PREFIX)

    def initialize(agent:, input:, run_id:)
      super(agent: agent, input: input)
      @run_id = run_id.to_s
    end

    private

    def authorize!
      refuse!("fallback_off", "Paid fallback is switched off on this house.") unless Setting.instance.paid_fallback_enabled?
      @policy = @agent.fallback_policy
      unless @policy&.enabled? && @input["model"] == self.class.model_id_for(@policy.model_id)
        refuse!("fallback_model_unavailable", "This model is not the resident's paid fallback.")
      end
      @turn = open_turn
      refuse!("fallback_off", "Paid fallback is only for a turn the house moved to it.") unless @turn
      Models.offering(@policy.model_id) or refuse!("fallback_model_unavailable", "This model is no longer one the fallback can use.")
    end

    # The fallback turn this call belongs to: its run is this resident's,
    # still running, and was opened on the model the policy names now.
    def open_turn
      return unless @run_id.match?(/\A\d{1,18}\z/)

      run = @agent.agent_runtime_interactions.find_by(id: @run_id, finished_at: nil)
      run && ResidentFallbackTurn.find_by(agent: @agent, fallback_interaction: run, fallback_model_id: @policy.model_id)
    end

    def upstream_key
      @policy.payer_key or refuse!("fallback_payer_key_missing", Decision.reason_for("fallback_payer_key_missing", agent: @agent, policy: @policy))
    end

    def reserve!(_offering, body)
      call = Decision.admit_call!(@agent, input_bound_tokens: HouseInference::Request.input_bound(@input),
        max_output_tokens: body.fetch("max_tokens"), turn: @turn)
      LedgerCall.new(call, sent: -> { sent? })
    rescue Decision::Refused => e
      refuse!(e.code, e.message)
    end

    def provider_refused(reason)
      HouseInference::Error.new("The paid fallback's provider could not complete this request.",
        code: "fallback_provider_refused", status: 502, reason: reason)
    end

    def refuse!(code, message)
      raise HouseInference::Error.new(message, code: code, status: code == "fallback_cap_reached" ? 402 : 403)
    end

    # The house gateway's settle!/release! in the fallback ledger's terms.
    # Unlike a house-funded call, the owner's key pays: a call that may have
    # reached the provider is never released, refused or not (Mira, #871).
    class LedgerCall

      SOURCE = "openrouter_usage_cost".freeze

      def initialize(call, sent:)
        @call, @sent = call, sent
      end

      attr_reader :call

      def settle!(usage, upstream_id: nil)
        cost, = HouseInference::UsageCost.call(usage)
        return @call.unresolved!(upstream_id: upstream_id) if cost.nil?

        @call.settle!(cost, source: SOURCE, upstream_id: upstream_id)
      end

      def release!(http_status: nil, upstream_id: nil, refusal_reason: nil)
        return @call.unresolved!(http_status: http_status, upstream_id: upstream_id) if @sent.call

        @call.not_sent!
      end

    end

  end
end

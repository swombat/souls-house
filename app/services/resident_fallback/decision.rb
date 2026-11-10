# Whether a resident may answer on its paid fallback (#690), and the one
# place a paid call is admitted. Admission is per provider call, not per turn:
# a Chaos turn is many calls, and only a call whose worst case fits inside
# what is left of the owner's cap is sent. A turn can therefore stop part way
# when its next call doesn't fit; it never runs past the cap.
#
# Refusal codes become the run's failure category (FailureReport), so the
# owner and the room read why. `fallback_off` refuses nothing: a resident
# whose owner hasn't opted in behaves exactly as before.
module ResidentFallback
  class Decision

    REFUSALS = %w[fallback_payer_key_missing fallback_cap_reached fallback_model_unavailable].freeze

    class Refused < StandardError

      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end

    end

    attr_reader :agent, :policy, :code

    def self.for(agent, at: Time.current)
      new(agent, at: at)
    end

    def initialize(agent, at: Time.current)
      @agent = agent
      @at = at
      @policy = agent.fallback_policy
      @code = decide
    end

    def ok? = code.nil?

    def off? = code == "fallback_off"

    def refused? = REFUSALS.include?(code)

    def reason
      self.class.reason_for(code, agent: agent, policy: policy, at: @at)
    end

    def self.reason_for(code, agent:, policy:, at: Time.current)
      case code
      when "fallback_payer_key_missing"
        "#{agent.name}'s paid fallback is on, but this account has no #{policy.payer_name} key of its own, so it can't run."
      when "fallback_cap_reached"
        "#{agent.name}'s paid fallback has reached its cap of $#{format('%.2f', policy.cap_usd)} this #{policy.cap_period}. " \
          "It can run again from #{policy.period_end(at).utc.to_date.to_fs(:long)} (UTC)."
      when "fallback_model_unavailable"
        "#{agent.name}'s paid fallback model is no longer one the fallback can use."
      end
    end

    # Admit one paid call: under the policy's row lock, refuse unless its
    # worst case fits in what is left of the cap, then hold that worst case
    # as a pending call. Concurrent calls from every conversation queue on
    # the same lock and see each other's reservations.
    def self.admit_call!(agent, input_bound_tokens:, max_output_tokens:, turn: nil, at: Time.current)
      policy = agent.fallback_policy or raise Refused.new("fallback_off", "Paid fallback is off.")
      policy.with_lock do
        code = new(agent, at: at).code
        raise Refused.new(code, reason_for(code, agent: agent, policy: policy, at: at)) if code

        config = policy.model_config
        max_output = [ max_output_tokens.to_i, config.fetch(:max_output_tokens) ].min
        reservation = Models.reservation_usd(policy.model_id, input_bound_tokens: input_bound_tokens, max_output_tokens: max_output)
        if policy.committed_usd(at) + reservation > policy.cap_usd
          raise Refused.new("fallback_cap_reached", reason_for("fallback_cap_reached", agent: agent, policy: policy, at: at))
        end

        ResidentFallbackCall.create!(
          agent: agent, resident_fallback_turn: turn, admitted_at: at,
          upstream_model: config.fetch(:upstream_model), max_price: config.fetch(:max_price),
          input_bound_tokens: input_bound_tokens, max_output_tokens: max_output, reservation_usd: reservation
        )
      end
    end

    private

    def decide
      return "fallback_off" unless policy&.enabled?
      return "fallback_model_unavailable" unless policy.model_config
      return "fallback_payer_key_missing" unless policy.payer_key
      return "fallback_cap_reached" if policy.committed_usd(@at) >= policy.cap_usd

      nil
    end

  end
end

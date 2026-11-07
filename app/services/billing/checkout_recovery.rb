module Billing
  # Operator-only recovery. It cannot clear an unknown attempt or start a charge:
  # it binds a discovered session, whose normal status checks still apply.
  class CheckoutRecovery

    def self.attach!(attempt:, session_id:, operator:, reason:, client: Billing.client)
      raise ArgumentError, "Name the operator and reconciliation reason" if operator.blank? || reason.blank?

      CheckoutLock.synchronize(attempt.agent) do
        attempt.reload
        raise NotReady, "This attempt is already resolved" if attempt.resolved_at?
        if attempt.stripe_session_id? && attempt.stripe_session_id != session_id
          raise NotReady, "This attempt already names a different session"
        end

        session = client.v1.checkout.sessions.retrieve(session_id)
        expected = attempt.create_params
        actual_metadata = session.metadata.to_h.stringify_keys
        unless session.mode == "subscription" &&
            session.client_reference_id.to_s == attempt.agent_id.to_s &&
            stripe_id(session.customer) == expected.fetch("customer") &&
            expected.fetch("metadata").all? { |key, value| actual_metadata[key].to_s == value.to_s }
          raise InvalidSubscription, "That session does not match this Checkout attempt"
        end

        ApplicationRecord.transaction do
          attempt.update!(stripe_session_id: session.id)
          AuditLog.create!(account: attempt.account, auditable: attempt.agent,
            action: "billing_checkout_reconciled", data: {
              "attempt_id" => attempt.id, "stripe_session_id" => session.id,
              "operator" => operator, "reason" => reason
            })
        end
        attempt
      end
    end

    def self.stripe_id(value) = value.respond_to?(:id) ? value.id : value
    private_class_method :stripe_id

  end
end

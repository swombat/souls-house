namespace :billing do
  namespace :checkout do
    desc "Bind a discovered Stripe session to an unknown attempt (ATTEMPT_ID SESSION_ID OPERATOR REASON)"
    task reconcile: :environment do
      attempt = BillingCheckoutAttempt.find(ENV.fetch("ATTEMPT_ID"))
      Billing::CheckoutRecovery.attach!(attempt: attempt,
        session_id: ENV.fetch("SESSION_ID"), operator: ENV.fetch("OPERATOR"), reason: ENV.fetch("REASON"))
      puts "Reconciled Checkout attempt #{attempt.id}; no charge or entitlement change. Retry the owner's Checkout."
    end
  end
end

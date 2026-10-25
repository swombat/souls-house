# Paying for a resident as the last step of creating it, in an account that
# pays per resident (Daniel, oewbQY 2026-10-25).
#
#   start!     records the draft as a ResidentBirthOrder and creates the
#              plan's subscription at Stripe with its first invoice open.
#              The browser confirms that payment with the account's saved
#              card (Stripe.js handles any bank check, 3-D Secure).
#   complete!  once Stripe says the subscription is paid, creates the
#              resident through the ordinary birth, names it on the
#              subscription and brings the subscription in, so the plan is
#              in force from the resident's first moment.
#
# complete! runs from the browser after confirming and from the webhook, in
# either order or both; the order's row lock makes the birth happen once.
# Nothing is born before money has cleared, and an order never paid is
# abandoned by the sweeper (its subscription cancelled, its draft cleared).
module Billing
  class PaidBirth

    class Refused < StandardError; end

    PAID = ResidentSubscription::PAID_STATUSES

    def initialize(client: Billing.client)
      @client = client
    end

    # Returns [order, client_secret, payment_method_id].
    def start!(account:, creator:, attributes:, open_beginning:, tier:)
      refuse!(account, creator, tier)
      payment_method = PaymentMethod.new(account: account, client: @client).current ||
        raise(Refused, "Add a card to pay for the plan first.")
      Agents::VmBirthPolicy.current.refuse!(kind: :birth)
      if attributes[:name].to_s.strip.empty?
        raise Refused, "Give the resident a name first."
      end
      if attributes[:system_prompt].to_s.strip.empty? && !open_beginning
        raise Refused, "Write a soul seed, or choose an open beginning."
      end

      customer = BillingCustomer.find_by!(account: account)
      order = ResidentBirthOrder.transaction do
        abandon_earlier!(account, creator)
        ResidentBirthOrder.create!(account: account, creator: creator, tier: tier.id,
          birth_attributes: attributes.to_h, open_beginning: open_beginning)
      end
      subscription = @client.v1.subscriptions.create({
        customer: customer.stripe_customer_id,
        items: [ { price: tier.price_id } ],
        default_payment_method: payment_method.id,
        payment_behavior: "default_incomplete",
        payment_settings: { save_default_payment_method: "on_subscription" },
        automatic_tax: { enabled: true },
        description: "#{tier.name} hosting for #{order.resident_name}",
        metadata: { birth_order_id: order.id.to_s, account_id: account.id.to_s, tier: tier.id },
        expand: [ "latest_invoice.confirmation_secret" ]
      }, { idempotency_key: "souls-house-birth-order-#{order.id}" })
      order.update!(stripe_subscription_id: subscription.id)
      [ order, client_secret(subscription), payment_method.id ]
    rescue Stripe::StripeError
      order&.update!(state: "abandoned", birth_attributes: {}) if order&.pending? && order.stripe_subscription_id.nil?
      raise
    end

    # A fresh secret for paying an order's open invoice again, after a
    # decline or with a different card. The card now on the account becomes
    # the subscription's.
    def payment(order)
      raise Refused, "This resident is no longer waiting for payment." unless order.pending?

      payment_method = PaymentMethod.new(account: order.account, client: @client).current ||
        raise(Refused, "Add a card to pay for the plan first.")
      subscription = @client.v1.subscriptions.update(order.stripe_subscription_id,
        { default_payment_method: payment_method.id, expand: [ "latest_invoice.confirmation_secret" ] })
      [ client_secret(subscription), payment_method.id ]
    end

    # Returns the order, born if its subscription is paid. A birth that fails
    # after payment rolls back everything it made, then records the order as
    # failed outside that transaction so the record survives.
    def complete!(order)
      failure = nil
      remote = nil
      order.with_lock do
        next unless order.pending? || order.failed?

        remote = @client.v1.subscriptions.retrieve(order.stripe_subscription_id)
        next unless remote.status.in?(PAID)

        begin
          bear!(order, remote)
        rescue ActiveRecord::RecordInvalid, Agents::HostedProvisioning::ConfigurationError => error
          failure = error
          raise ActiveRecord::Rollback
        end
      end
      fail!(order, remote, failure) if failure
      order
    end

    # The sweeper's: an order still unpaid at expires_at is abandoned. One
    # paid at the last moment is born instead.
    def abandon_expired!(order)
      order.with_lock { abandon!(order) if order.pending? }
    end

    private

    def refuse!(account, creator, tier)
      raise Refused, "This account doesn't pay per resident." unless account.billing_required?
      raise Refused, "Only the account's owner can pay for a new resident." unless account.owned_by?(creator)
      raise Refused, "Paying for residents isn't open on this house yet." unless Billing.configured?
      raise Refused, "That plan can't be bought yet." unless tier&.purchasable?
    end

    # One open order per person and account: asking again replaces the
    # earlier one, whose unpaid subscription is cancelled.
    def abandon_earlier!(account, creator)
      ResidentBirthOrder.pending.where(account: account, creator: creator).find_each do |earlier|
        abandon!(earlier)
      end
    end

    def abandon!(order)
      if order.stripe_subscription_id.present?
        remote = @client.v1.subscriptions.retrieve(order.stripe_subscription_id)
        return complete!(order) if remote.status.in?(PAID)

        @client.v1.subscriptions.cancel(order.stripe_subscription_id) if remote.status == "incomplete"
      end
      order.update!(state: "abandoned", birth_attributes: {})
    end

    # The resident is born through the ordinary path (VM placement, runtime,
    # first wake), without the free house grant: the plan's allowance
    # replaces it. If the birth fails after payment, the order is kept as
    # failed with its draft, and a site admin is told; the owner can retry.
    def bear!(order, remote)
      attributes = order.birth_attributes.symbolize_keys
      agent = Agents::HostedBirth.new(account: order.account, creator: order.creator, attributes: attributes,
        open_beginning: order.open_beginning, paid: true).create!
      @client.v1.subscriptions.update(remote.id, {
        metadata: { agent_id: agent.id.to_s, birth_order_id: order.id.to_s },
        description: "#{order.tier_record.name} hosting for #{agent.name}"
      })
      order.update!(state: "born", agent: agent, born_at: Time.current, birth_attributes: {}, last_error: nil)
      SubscriptionSync.new(remote.id, client: @client).call
    end

    def fail!(order, remote, error)
      order.reload.update!(state: "failed", last_error: error.message.first(500))
      Rails.error.report(error, handled: true,
        context: { subsystem: "billing", birth_order_id: order.id, stripe_subscription_id: remote&.id })
      raise error
    end

    def client_secret(subscription)
      subscription.latest_invoice&.confirmation_secret&.client_secret ||
        raise(Refused, "Stripe didn't open the first payment. Try again in a moment.")
    end

  end
end

# One Stripe customer per account. The account's owner pays for every
# resident the account hosts; each resident has its own subscription.
class BillingCustomer < ApplicationRecord

  belongs_to :account

  # Uniqueness of both is the indexes' job, so create_or_find_by! can see a race.
  validates :stripe_customer_id, presence: true

  # Creates the Stripe customer once. The idempotency key and the unique index
  # keep a double click from making two.
  def self.for!(account, client: Billing.client)
    find_by(account: account) || begin
      customer = client.v1.customers.create(
        {
          name: account.name,
          email: account.owner&.email_address,
          metadata: { account_id: account.id.to_s }
        },
        { idempotency_key: "souls-house-customer-#{account.id}" }
      )
      create_or_find_by!(account: account) { |record| record.stripe_customer_id = customer.id }
    end
  end

end

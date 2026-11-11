# An attempt can now add an item to the account's live subscription instead of
# opening a Checkout (eoXAEj slice 2a). Its parent, the server's quote, and
# when the pinned update was first sent to Stripe are kept with it.
class BillingCheckoutAttemptsForItems < ActiveRecord::Migration[8.1]

  def change
    add_column :billing_checkout_attempts, :kind, :string, null: false, default: "checkout"
    add_column :billing_checkout_attempts, :stripe_subscription_id, :string
    add_column :billing_checkout_attempts, :stripe_subscription_item_id, :string
    add_column :billing_checkout_attempts, :quote, :jsonb
    add_column :billing_checkout_attempts, :submitted_at, :datetime
  end

end

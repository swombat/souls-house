# One Stripe subscription per account, one item per resident (eoXAEj).
# A ResidentSubscription becomes one item of a subscription: the item id is
# its identity, and several rows may share a subscription id. Rows written
# before this have no item id yet; the first sync records it, and until then
# a subscription id still names at most one of them.
#
# billing_customers.stripe_subscription_id is the account's one subscription,
# once it has one; nothing reads it yet.
class ResidentSubscriptionsPerItem < ActiveRecord::Migration[8.1]

  def change
    add_column :resident_subscriptions, :stripe_subscription_item_id, :string
    add_index :resident_subscriptions, :stripe_subscription_item_id, unique: true,
      where: "stripe_subscription_item_id IS NOT NULL"

    remove_index :resident_subscriptions, :stripe_subscription_id, unique: true,
      name: "index_resident_subscriptions_on_stripe_subscription_id"
    add_index :resident_subscriptions, :stripe_subscription_id
    add_index :resident_subscriptions, :stripe_subscription_id, unique: true,
      where: "stripe_subscription_item_id IS NULL", name: "one_unitemised_row_per_subscription"

    add_column :billing_customers, :stripe_subscription_id, :string
    add_index :billing_customers, :stripe_subscription_id, unique: true, where: "stripe_subscription_id IS NOT NULL"
  end

end

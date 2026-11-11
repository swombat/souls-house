# A paid creation can now add the new resident to the account's live
# subscription as one more item instead of opening a subscription of its own
# (eoXAEj slice 2b). The order keeps its kind (pinned when it is made), the
# pinned update and the quote the owner confirmed, when that update was first
# sent, and the item Stripe made for it. Several item orders share one
# subscription, so only subscription orders keep it unique.
class ResidentBirthOrdersForItems < ActiveRecord::Migration[8.1]

  def change
    add_column :resident_birth_orders, :kind, :string, null: false, default: "subscription"
    add_column :resident_birth_orders, :stripe_subscription_item_id, :string
    add_column :resident_birth_orders, :item_create_params, :jsonb
    add_column :resident_birth_orders, :item_quote, :jsonb
    add_column :resident_birth_orders, :item_submitted_at, :datetime
    add_index :resident_birth_orders, :stripe_subscription_item_id, unique: true,
      where: "stripe_subscription_item_id IS NOT NULL"
    # Item orders share the account's subscription; a subscription order
    # still owns its own.
    remove_index :resident_birth_orders, :stripe_subscription_id, unique: true
    add_index :resident_birth_orders, :stripe_subscription_id, unique: true, where: "kind = 'subscription'",
      name: "index_resident_birth_orders_on_stripe_subscription_id"
    add_index :resident_birth_orders, :stripe_subscription_id, where: "kind = 'item'",
      name: "index_resident_birth_orders_items_on_stripe_subscription_id"
  end

end

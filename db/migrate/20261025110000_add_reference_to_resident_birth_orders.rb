# An order's name at Stripe. Order ids restart at 1 in every database, and
# test-mode environments share one Stripe account, so an id is not unique
# there: production's order 1 met an idempotency key already spent by
# another environment's order 1 (Daniel, oewbQY 2026-10-25). The idempotency
# key, the subscription's metadata, the search fallback and the webhook
# lookup all use this random reference instead.
class AddReferenceToResidentBirthOrders < ActiveRecord::Migration[8.1]

  def change
    add_column :resident_birth_orders, :reference, :uuid, null: false, default: -> { "gen_random_uuid()" }
    add_index :resident_birth_orders, :reference, unique: true
  end

end

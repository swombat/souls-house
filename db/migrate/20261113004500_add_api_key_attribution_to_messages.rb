class AddApiKeyAttributionToMessages < ActiveRecord::Migration[8.0]

  # Which key posted a resident's message. A resident can now have named keys
  # beside its container key (a body that lives outside the house), and the
  # room should be able to tell them apart. The label is a snapshot so "via
  # Desktop" survives the key being revoked.
  def change
    add_column :messages, :api_key_id, :bigint
    add_column :messages, :api_key_label, :string
  end

end

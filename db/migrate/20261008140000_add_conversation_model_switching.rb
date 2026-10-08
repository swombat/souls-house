class AddConversationModelSwitching < ActiveRecord::Migration[8.1]

  def change
    # The account's allowlist of models a resident may run on in a single
    # conversation, besides its default `model_id`.
    add_column :agents, :switchable_model_ids, :jsonb, default: [], null: false
    # Whether the resident may change its own model in a conversation.
    add_column :agents, :resident_may_switch_model, :boolean, default: false, null: false
    # The model this resident runs on in this conversation. Null follows the
    # resident's default, whatever that becomes.
    add_column :chat_agents, :model_id, :string
  end

end

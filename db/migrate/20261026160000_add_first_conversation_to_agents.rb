# A resident born from now on speaks first: the house opens a conversation
# with the person who created it and wakes it there once (FirstConversation).
#
# created_by_user_id  who asked for the birth (every birth path passes it to
#                     Agents::HostedBirth). Residents born before this have
#                     none, which is also what keeps the greeting to new births.
# first_conversation_chat_id  the conversation opened, or the one a person had
#                     already started (then no greeting is owed).
# first_conversation_greeting  owed | sent (a run is reserved) | spent (the
#                     request reached the runtime client; final) | skipped. "owed" is written in the
#                     same transaction as the chat, so a process dying before
#                     the wake is enqueued leaves it owed for the sweep.
# first_conversation_interaction_id  the reserved run carrying the greeting,
#                     committed with "sent". Whether the greeting was spent is
#                     read from that run (did the request reach the client?),
#                     never from a response status.
# first_conversation_attempts  reservations made; unsent ones are retried, a
#                     few times at most.
class AddFirstConversationToAgents < ActiveRecord::Migration[8.1]

  def change
    add_reference :agents, :created_by_user, foreign_key: { to_table: :users, on_delete: :nullify }, null: true
    add_reference :agents, :first_conversation_chat, foreign_key: { to_table: :chats, on_delete: :nullify }, null: true
    add_column :agents, :first_conversation_greeting, :string
    add_column :agents, :first_conversation_woken_at, :datetime
    add_reference :agents, :first_conversation_interaction,
      foreign_key: { to_table: :agent_runtime_interactions, on_delete: :nullify }, null: true
    add_column :agents, :first_conversation_attempts, :integer, default: 0, null: false
    add_check_constraint :agents,
      "first_conversation_greeting IS NULL OR first_conversation_greeting IN ('owed', 'sent', 'spent', 'skipped')",
      name: "agents_first_conversation_greeting_values"
  end

end

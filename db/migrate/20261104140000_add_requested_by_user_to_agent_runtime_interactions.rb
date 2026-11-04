# The person whose button press reserved a run (Chat#request_agent_response!).
# A run a person asked for by tapping had no record of who asked, so when it
# came back busy there was no authority to carry into a retry (#781): the
# retry re-queues a PendingWake with this person as its source, and the wake's
# own checks (still a member, room still respondable) decide at release and
# at claim. Nullified if the user is deleted, which withdraws that source.
class AddRequestedByUserToAgentRuntimeInteractions < ActiveRecord::Migration[8.1]
  def change
    add_reference :agent_runtime_interactions, :requested_by_user,
      foreign_key: { to_table: :users, on_delete: :nullify }, index: { where: "requested_by_user_id IS NOT NULL" }
  end
end

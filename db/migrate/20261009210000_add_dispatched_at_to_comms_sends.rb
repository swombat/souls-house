# When a send was handed to the connector (moved from pending to unknown).
# The send rate limit counts sends by this time, not by when they were
# requested, so a backlog of old pending claims retried together is still
# paced (spec §5).
class AddDispatchedAtToCommsSends < ActiveRecord::Migration[8.1]

  def change
    add_column :comms_sends, :dispatched_at, :datetime
    add_index :comms_sends, [ :service_connection_id, :dispatched_at ]
  end

end

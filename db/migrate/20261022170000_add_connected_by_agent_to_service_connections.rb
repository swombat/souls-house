# A resident that set a connection up itself (issue #500). connected_by_user
# stays the person it was set up for; this records who actually acted.
class AddConnectedByAgentToServiceConnections < ActiveRecord::Migration[8.1]

  def change
    add_reference :service_connections, :connected_by_agent, foreign_key: { to_table: :agents, on_delete: :nullify }, index: true
  end

end

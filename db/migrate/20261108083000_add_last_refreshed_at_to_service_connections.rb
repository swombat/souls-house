class AddLastRefreshedAtToServiceConnections < ActiveRecord::Migration[8.1]

  def change
    add_column :service_connections, :last_refreshed_at, :datetime
  end

end

class AddReportedCeilingToCompanionDevices < ActiveRecord::Migration[8.1]

  # The companion's own report of its local ceiling (volume keys and access
  # per resident), replaced whole on each connection. Display and a
  # consistency check for the owner page only; it authorises nothing.
  def change
    add_column :companion_devices, :reported_ceiling, :jsonb
    add_column :companion_devices, :ceiling_reported_at, :datetime
    add_column :companion_devices, :ceiling_epoch, :string
  end

end

class DefaultNewResidentsToPersistentSessions < ActiveRecord::Migration[8.1]

  def change
    # Defaults affect new records only. Existing residents retain their choices,
    # including an explicit false restored from a portable home.
    change_column_default :agents, :persistent_session, from: false, to: true
    change_column_default :agents, :persistent_wake_session, from: false, to: true
  end

end

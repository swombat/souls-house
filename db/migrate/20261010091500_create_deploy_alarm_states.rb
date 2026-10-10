# One row: whether production follows master, as DeployAlarmCheckJob last
# saw it. It exists to catch an absence of progress (a deploy that never
# happened), which no event can carry.
class CreateDeployAlarmStates < ActiveRecord::Migration[8.1]

  def change
    create_table :deploy_alarm_states do |t|
      t.string :state, null: false, default: "ok"
      t.datetime :since
      t.string :deployed_sha
      t.string :master_sha
      t.integer :behind_by
      t.datetime :behind_since
      t.datetime :unknown_since
      t.string :reason
      t.string :last_run_url
      t.datetime :notified_at
      t.string :notified_master_sha
      t.datetime :last_checked_at
      t.text :last_error
      t.timestamps
    end
  end

end

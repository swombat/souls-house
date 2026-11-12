# Power state for Boat placements (slice 2, PR 3 of resident placement,
# ePokyY). A Boat sandbox can be stopped (archived) and resumed; the house
# wakes it before handing its runner work, and stops it only under the stop
# protocol in BoatPower. Every column is null or zero for other backends.
#
# power_epoch is bumped on every stop intent and every wake intent. A worker
# may send a stop only by winning a compare-and-set on (epoch, stopping,
# stop_sent_at IS NULL), so a stale worker sends nothing. stop_id and
# stop_epoch record the stop the house has evidence is its own, and for which
# epoch. wake_request_version is bumped by every command enqueued for the
# placement; wake_satisfied_version catches up only on a heartbeat stamped
# with the current epoch. power_review_at turns every stop off for the
# placement until an operator clears it.
class AddBoatPowerToAgentPlacements < ActiveRecord::Migration[8.0]

  POWER_STATES = %w[awake stopping stopped waking].freeze

  def change
    change_table :agent_placements, bulk: true do |t|
      t.string :power_state
      t.integer :power_epoch, null: false, default: 0
      t.integer :wake_request_version, null: false, default: 0
      t.integer :wake_satisfied_version, null: false, default: 0
      t.datetime :stop_sent_at
      t.string :stop_id
      t.integer :stop_epoch
      t.datetime :power_changed_at
      t.datetime :power_review_at
      t.string :power_review_reason
    end

    add_check_constraint :agent_placements,
      "power_state IS NULL OR power_state IN (#{POWER_STATES.map { |s| "'#{s}'" }.join(', ')})",
      name: "agent_placements_power_state"
    add_check_constraint :agent_placements, "power_state IS NULL OR backend = 'boat'",
      name: "agent_placements_power_state_boat_only"
    add_check_constraint :agent_placements, "wake_satisfied_version <= wake_request_version",
      name: "agent_placements_wake_versions"
    # Only a Boat placement ever sends a stop.
    add_check_constraint :agent_placements, "stop_sent_at IS NULL OR power_state IS NOT NULL",
      name: "agent_placements_stop_sent_boat_only"

    reversible do |dir|
      dir.up { execute "UPDATE agent_placements SET power_state = 'awake' WHERE backend = 'boat'" }
    end
  end

end

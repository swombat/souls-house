class AddVolumeMapToAgents < ActiveRecord::Migration[8.1]

  # #426 3C checkpoint 3 (rollback). volume_map: when set, the complete map of
  # the resident's five Docker volumes (identity, chaos, repo, work, state),
  # read only by Agents::Resources#volumes. Nil means today's derived names,
  # exactly as before this column existed. A rollback restores into fresh
  # volumes and then swaps by setting this map in one commit.
  #
  # volume_rollback_generation: the last rollback generation handed out for
  # this resident. It only ever rises, under the agent's row lock, so two
  # rollbacks never name the same fresh volumes and a failed attempt's names
  # are never reused.
  def change
    add_column :agents, :volume_map, :jsonb
    add_column :agents, :volume_rollback_generation, :integer, null: false, default: 0
  end

end

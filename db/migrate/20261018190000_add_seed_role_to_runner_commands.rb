class AddSeedRoleToRunnerCommands < ActiveRecord::Migration[8.1]

  # Which volume an archive import's seed_home names. Kept in its own column
  # because a command's payload is dropped once it is answered.
  def change
    add_column :runner_commands, :seed_role, :string
    add_check_constraint :runner_commands, "seed_role IS NULL OR (kind = 'seed_home' AND seed_role IN ('identity', 'repo', 'work'))",
      name: "runner_commands_seed_role"
  end

end

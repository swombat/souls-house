class AddCreatedByAgentToWatchedRepositories < ActiveRecord::Migration[8.1]

  def change
    add_reference :watched_repositories, :created_by_agent, foreign_key: { to_table: :agents, on_delete: :nullify }, index: true
  end

end

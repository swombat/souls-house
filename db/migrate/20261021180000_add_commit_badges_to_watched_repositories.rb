class AddCommitBadgesToWatchedRepositories < ActiveRecord::Migration[8.1]

  def change
    add_column :watched_repositories, :commit_badges, :boolean, default: false, null: false
  end

end

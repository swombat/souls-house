class AddAgentDeprecation < ActiveRecord::Migration[8.0]

  def change
    add_column :agents, :deprecated_at, :datetime
    add_column :agents, :deprecation_reason, :string
    change_column_default :agents, :runtime, from: "inline", to: "deprecated"
  end

end

# Two switches gate the reflex check (#515). The site admin chooses off /
# chosen residents / everyone, as for follow-through; an account admin can
# keep reflexes off for the account's residents whatever the site says.
# Authoring stays available with both off.
class AddReflexSwitches < ActiveRecord::Migration[8.1]

  def change
    add_column :settings, :reflexes_scope, :string, default: "off", null: false
    add_column :agents, :reflexes_chosen, :boolean, default: false, null: false
    add_column :accounts, :reflexes_enabled, :boolean, default: false, null: false
  end

end

# Reflexes site scope becomes three states (Daniel, BYZnpY, 2026-10-23, #520):
# disabled (off everywhere, whatever an account says), account_choice (each
# account's own switch decides) and enabled (on for every account, whatever
# it says). There is no per-resident list any more, so agents.reflexes_chosen
# goes. An account's own switch is untouched by any of this: it survives a
# site override and counts again under account_choice.
class ReflexesSiteScopeThreeStates < ActiveRecord::Migration[8.1]

  def up
    change_column_default :settings, :reflexes_scope, from: "off", to: "disabled"
    execute <<~SQL.squish
      UPDATE settings SET reflexes_scope = CASE reflexes_scope
        WHEN 'all' THEN 'enabled'
        WHEN 'selected' THEN 'account_choice'
        ELSE 'disabled'
      END
    SQL
    remove_column :agents, :reflexes_chosen
  end

  def down
    add_column :agents, :reflexes_chosen, :boolean, default: false, null: false
    execute <<~SQL.squish
      UPDATE settings SET reflexes_scope = CASE reflexes_scope
        WHEN 'enabled' THEN 'all'
        WHEN 'account_choice' THEN 'selected'
        ELSE 'off'
      END
    SQL
    change_column_default :settings, :reflexes_scope, from: "disabled", to: "off"
  end

end

# The house-held journal_source went in #1139: a resident's card counts the
# journal its own resident-home.json declares. Agent has ignored the column
# since that deploy, so no running process reads or writes it.
class RemoveJournalSourceFromAgents < ActiveRecord::Migration[8.1]
  def change
    remove_column :agents, :journal_source, :string
  end
end

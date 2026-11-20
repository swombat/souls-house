# Which journal the resident's card counts (JqRaEY, Janis 2026-11-20): null
# is the dated daily journals; otherwise one Markdown file under memory/,
# relative to /home/agent/identity, chosen by the resident and recorded in
# Site Admin.
class AddJournalSourceToAgents < ActiveRecord::Migration[8.0]

  def change
    add_column :agents, :journal_source, :string
  end

end

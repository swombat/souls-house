class AddRichUiToMessages < ActiveRecord::Migration[8.1]

  def change
    add_column :messages, :rich_ui, :jsonb
  end

end

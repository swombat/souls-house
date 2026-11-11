# A stone's write link (slice 3 of Field tables): whoever holds the stone's
# link with this key in its fragment can add rows to the tables the stone
# reads. Stored encrypted; nil means the stone can't write.
class AddWriteKeyToStones < ActiveRecord::Migration[8.1]

  def change
    add_column :stones, :write_key, :string
    add_column :stones, :write_key_created_at, :datetime
  end

end

class CreateFieldFiles < ActiveRecord::Migration[8.1]

  def change
    create_table :field_files do |t|
      t.references :account, null: false, foreign_key: true
      t.references :uploaded_by, polymorphic: true
      t.string :title, null: false, limit: 200
      t.text :note
      t.datetime :discarded_at
      t.timestamps
    end
    add_index :field_files, [ :account_id, :created_at ]
    add_index :field_files, :discarded_at
  end

end

class CreateFieldFiles < ActiveRecord::Migration[8.1]

  def change
    create_table :field_files do |t|
      t.references :account, null: false, foreign_key: true
      t.references :uploaded_by, polymorphic: true
      t.string :title, null: false, limit: 200
      t.text :note
      t.timestamps
    end
    add_index :field_files, [ :account_id, :created_at ]
  end

end

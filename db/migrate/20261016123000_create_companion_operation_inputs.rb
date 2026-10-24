class CreateCompanionOperationInputs < ActiveRecord::Migration[8.1]

  def change
    create_table :companion_operation_inputs do |t|
      t.references :companion_operation, null: false, index: { unique: true }, foreign_key: true
      t.binary :data, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :companion_operation_inputs, :expires_at
  end

end

class CreateHouseInference < ActiveRecord::Migration[8.0]

  def change
    create_table :house_inference_grants do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.references :agent, foreign_key: true, index: { unique: true }
      t.timestamps
    end
    create_table :house_inference_calls do |t|
      t.references :house_inference_grant, null: false, foreign_key: true
      t.date :month, null: false
      t.string :model_id, null: false
      t.string :provider_route, null: false
      t.string :status, null: false, default: 'pending'
      t.decimal :charge_usd, precision: 14, scale: 8, null: false
      t.string :upstream_id
      t.timestamps
    end
    add_index :house_inference_calls, [ :house_inference_grant_id, :month ], name: 'index_house_calls_on_grant_month'
    add_index :house_inference_calls, :month
    add_check_constraint :house_inference_calls, 'charge_usd >= 0', name: 'house_calls_nonnegative_charge'
  end

end

# A commitment may recur (Daniel, eRNlOe YrBKBw): every N minutes, or a
# random pick between a minimum and a maximum. Each occurrence is its own
# row; series_root_id ties them together and previous_commitment_id makes
# the chain readable.
class AddRecurrenceToCommitments < ActiveRecord::Migration[8.1]

  def change
    add_column :commitments, :recur_min_minutes, :integer
    add_column :commitments, :recur_max_minutes, :integer
    add_column :commitments, :occurrence, :integer, default: 1, null: false
    add_reference :commitments, :series_root, foreign_key: { to_table: :commitments, on_delete: :nullify }, index: true
    add_reference :commitments, :previous_commitment, foreign_key: { to_table: :commitments, on_delete: :nullify }, index: { unique: true }
    add_column :commitments, :series_ended_reason, :string
  end

end

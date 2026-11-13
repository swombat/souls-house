class CreateHetznerAvailabilitySamples < ActiveRecord::Migration[8.0]

  # Whether Hetzner can sell the small shared server types, every five
  # minutes, so we can see when CX comes back (Daniel, 13 Nov). One row per
  # type and location per check; a check that could not ask Hetzner writes one
  # row per type with available NULL and the error code, so a gap in the graph
  # means "we couldn't check", never "unavailable". Kept in full for now:
  # about 7k rows a day.
  def change
    create_table :hetzner_availability_samples do |t|
      t.datetime :checked_at, null: false
      t.string :server_type, null: false
      t.string :location
      t.boolean :available
      t.string :error
      t.datetime :created_at, null: false
    end
    add_index :hetzner_availability_samples, [ :checked_at, :server_type ], name: "index_hetzner_availability_on_checked_at_and_type"
  end

end

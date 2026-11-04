# A VM's runner is fetched at birth by the digest its user_data pins (#779),
# so the bytes it pins must outlive a Rails release between render and fetch.
class AddRunnerBirthBundles < ActiveRecord::Migration[8.1]

  def change
    create_table :runner_birth_bundles do |t|
      t.string :sha256, null: false
      t.binary :bytes, null: false
      t.timestamps
      t.index :sha256, unique: true
    end

    add_column :runner_enrollments, :birth_bundle_sha256, :string
    add_column :runner_enrollments, :birth_bundle_fetches, :integer, default: 0, null: false
  end

end

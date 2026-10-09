class AddVmBirthSettings < ActiveRecord::Migration[8.1]

  def change
    add_column :settings, :new_residents_on_vm, :boolean, default: false, null: false
    add_column :settings, :vm_resident_limit, :integer, default: 0, null: false
  end

end

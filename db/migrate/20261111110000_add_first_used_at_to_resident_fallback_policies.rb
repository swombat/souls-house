# #690 slice C: the first time a resident answers on its paid fallback after
# the owner turned it on, the owner is told once. first_used_at records that
# the notice went; turning the fallback on again clears it.
class AddFirstUsedAtToResidentFallbackPolicies < ActiveRecord::Migration[8.1]

  def change
    add_column :resident_fallback_policies, :first_used_at, :datetime
  end

end

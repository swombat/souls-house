# Whether a Mac's companion reports that its person has turned on "Let
# residents run commands on this Mac" (the local execute lifecycle opt-in).
# Display only: nil means not reported (Linux, or an older companion); the
# Computers page uses an explicit false from the current connection to say
# why commands are refused. It never grants or refuses anything itself.
class AddExecuteLifecycleAcceptedToCompanionDevices < ActiveRecord::Migration[8.1]

  def change
    add_column :companion_devices, :execute_lifecycle_accepted, :boolean
  end

end

# Every reply a pocket device was sent in the last AUDIO_WINDOW, so a later
# reply never makes an earlier one's voice unfetchable (Mira, #1083).
class AddPocketRepliesToCompanionDevices < ActiveRecord::Migration[8.0]

  def change
    add_column :companion_devices, :pocket_replies, :jsonb, default: [], null: false
  end

end

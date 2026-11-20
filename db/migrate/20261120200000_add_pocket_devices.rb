# A pocket device (Paulina's M5 "stone", YZWBVe): a CompanionDevice that has
# no drives and runs no commands. It is bound to one resident and one
# conversation, can post a voice clip or photo there, and hears back only the
# reply to that clip. The binding is fixed on the grant at approval.
class AddPocketDevices < ActiveRecord::Migration[8.0]

  def change
    add_column :companion_pairings, :kind, :string, limit: 16, null: false, default: "computer"
    add_column :companion_pairings, :offered_capabilities, :jsonb
    change_column_null :companion_pairings, :offered_volumes, true

    add_column :companion_enrollment_grants, :kind, :string, limit: 16, null: false, default: "computer"
    add_reference :companion_enrollment_grants, :chat, foreign_key: true
    add_column :companion_enrollment_grants, :offered_capabilities, :jsonb

    add_column :companion_devices, :kind, :string, limit: 16, null: false, default: "computer"
    add_reference :companion_devices, :chat, foreign_key: true
    add_column :companion_devices, :offered_capabilities, :jsonb, null: false, default: []
    add_column :companion_devices, :mic_enabled, :boolean, null: false, default: false
    add_column :companion_devices, :camera_enabled, :boolean, null: false, default: false
    # Bumped on every capture change; "ready" and each "consent" carry it, and
    # only the current one reaches the socket (Mira, jLQOLG).
    add_column :companion_devices, :consent_revision, :integer, null: false, default: 0
    # The one submission waiting for its reply, and when it was made.
    add_column :companion_devices, :pocket_open_message_id, :bigint
    add_column :companion_devices, :pocket_opened_at, :datetime

    add_reference :messages, :companion_device, foreign_key: true
  end

end

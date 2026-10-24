# WhatsApp's "Link with phone number instead": the 8-character code the
# owner types into WhatsApp, kept like the pairing QR (encrypted, with its
# issue time and expiry). The phone number itself is never stored.
class AddPairingPhoneCodeToServiceConnections < ActiveRecord::Migration[8.1]

  def change
    add_column :service_connections, :pairing_phone_code, :text
    add_column :service_connections, :pairing_phone_code_issued_at, :datetime
    add_column :service_connections, :pairing_phone_code_expires_at, :datetime
  end

end

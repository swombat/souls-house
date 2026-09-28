class CreateAppCableTickets < ActiveRecord::Migration[8.0]

  # Native-app sync (issue #94 B, step 6). A device trades its bearer token for
  # a one-use, 60-second ticket and presents it in Sec-WebSocket-Protocol when
  # it opens the cable. Only the ticket's digest is stored.
  def change
    create_table :app_cable_tickets do |t|
      t.references :app_session, null: false, foreign_key: true
      t.string :token_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.datetime :created_at, null: false
    end
    add_index :app_cable_tickets, :token_digest, unique: true
  end

end

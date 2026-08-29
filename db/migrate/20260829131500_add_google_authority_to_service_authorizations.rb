class AddGoogleAuthorityToServiceAuthorizations < ActiveRecord::Migration[8.1]

  def change
    change_column_null :service_authorization_attempts, :access_profile, true
    add_column :service_authorization_attempts, :authority_selection, :jsonb, null: false, default: {}
    add_reference :service_authorization_attempts, :service_connection, foreign_key: true
  end

end

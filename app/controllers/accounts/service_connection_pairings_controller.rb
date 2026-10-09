# The pairing QR for a comms (WhatsApp) connection, as JSON for the owner's
# integrations page. Only the person who connected it sees the code: not
# account admins (who can still manage and disconnect it), other members, or
# residents. An expired code is cleared here and never served.
class Accounts::ServiceConnectionPairingsController < ApplicationController

  def show
    connection = current_account.service_connections.find_by_public_id!(params[:service_connection_id])
    raise ActiveRecord::RecordNotFound unless connection.owner?(Current.user)

    if connection.pairing_qr.present? && connection.current_pairing_qr.nil?
      connection.update_columns(pairing_qr: nil, pairing_qr_expires_at: nil, updated_at: Time.current)
    end

    response.headers["Cache-Control"] = "no-store"
    render json: { status: connection.status, qr: connection.current_pairing_qr }
  end

end

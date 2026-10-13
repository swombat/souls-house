# The pairing QR for a comms (WhatsApp) connection, as JSON for the owner's
# integrations page. Only the person who connected it sees the code: not
# account admins (who can still manage and disconnect it), other members, or
# residents. An expired code is cleared here and never served; only that
# code is cleared, never one the connector rotated in meanwhile.
class Accounts::ServiceConnectionPairingsController < ApplicationController

  before_action :set_connection

  def show
    connection = @connection

    if connection.pairing_qr.present? && connection.current_pairing_qr.nil?
      connection.clear_expired_pairing_qr!
    end

    json = { status: connection.status, qr: connection.current_pairing_qr }
    if connection.provider == "telegram"
      json[:login] = connection.login_state
      json[:generation] = connection.login_generation
    end
    render json: json
  end

  # POST .../pairing/restart (WhatsApp; Telegram restarts through its login
  # steps). Pairs again from the start: after the codes expired, an error,
  # or WhatsApp logging the device out. Owner only, like the QR itself.
  def restart
    return head :not_found if @connection.provider == "telegram"
    unless @connection.restart_pairing!
      return render json: { error: "This connection is not waiting to be linked" }, status: :conflict
    end

    @connection.definition.adapter.start_pairing(@connection)
    audit(:restart_service_pairing, @connection, provider: @connection.provider)
    render json: { status: @connection.status, qr: nil }
  rescue Services::AdapterError
    render json: { error: "Could not reach the WhatsApp connector. Try again in a moment." }, status: :bad_gateway
  end

  private

  def set_connection
    @connection = current_account.service_connections.find_by_public_id!(params[:service_connection_id])
    raise ActiveRecord::RecordNotFound unless @connection.owner?(Current.user)

    response.headers["Cache-Control"] = "no-store"
  end

end

# The pairing QR for a comms (WhatsApp) connection, as JSON for the owner's
# integrations page, and WhatsApp's phone number pairing code. Only the
# person who connected it sees either code: not account admins (who can
# still manage and disconnect it), other members, or residents. An expired
# code is cleared here and never served; only that code is cleared, never
# one the connector rotated in meanwhile.
class Accounts::ServiceConnectionPairingsController < ApplicationController

  # E.164: "+", a country code that does not start with 0, at most 15 digits.
  E164 = /\A\+[1-9]\d{6,14}\z/

  before_action :set_connection

  def show
    connection = @connection

    if connection.pairing_qr.present? && connection.current_pairing_qr.nil?
      connection.clear_expired_pairing_qr!
    end
    if connection.pairing_phone_code.present? && connection.current_pairing_phone_code.nil?
      connection.clear_expired_pairing_phone_code!
    end

    json = pairing_json(connection)
    if connection.provider == "telegram"
      json[:login] = connection.login_state
      json[:generation] = connection.login_generation
    end
    render json: json
  end

  # GET .../pairing/link (WhatsApp): the focused page Connect WhatsApp
  # opens, so that on a phone the pairing is the whole screen rather than a
  # card halfway down Integrations. The same pairing is also on that card.
  # The codes themselves still come only from show, by fetch.
  def link
    return head :not_found unless @connection.provider == "whatsapp"

    render inertia: "accounts/whatsapp_link", props: {
      account: current_account.as_json,
      connection: @connection.as_connection_json(current_user: Current.user),
      integrations_url: account_integrations_path(current_account)
    }
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
    # The new attempt comes with the answer: a phone number sent right
    # after must join it, not the attempt the page last polled.
    render json: pairing_json(@connection.reload)
  rescue Services::AdapterError
    render json: { error: "Could not reach the WhatsApp connector. Try again in a moment." }, status: :bad_gateway
  end

  # POST .../pairing/phone  { phone, attempt } (WhatsApp): link with the
  # phone number instead of the QR, for someone on the phone WhatsApp is on,
  # which cannot scan its own screen. The connector asks WhatsApp for an
  # 8-character code and posts it back (pairing.phone_code); the owner types
  # it into WhatsApp. The number is forwarded inside this request and kept
  # nowhere: no column, no connector_state, no audit field, no log line
  # (filter_parameters covers "phone"). attempt is the pairing attempt the
  # owner's page shows, so a number never joins a newer attempt. Owner only.
  def phone
    return head :not_found unless @connection.provider == "whatsapp"

    phone = normalized_phone(params[:phone])
    unless phone
      return render json: { error: "Enter the number of the phone WhatsApp is on: + and the country code, then the number." },
                    status: :unprocessable_entity
    end
    attempt = Integer(params[:attempt].to_s, exception: false)
    return render json: { error: "Reload the page and try again." }, status: :unprocessable_entity if attempt.nil?
    request = @connection.request_phone_pairing!(attempt)
    unless request
      return render json: { error: "This pairing has moved on. Reload the page and try again." }, status: :conflict
    end
    seq = @connection.phone_pairing_state["seq"]

    begin
      # :superseded (the connector already took a newer request) is no
      # failure: the newer request is the one being answered. Answered as
      # accepted, with the pairing as it now stands.
      @connection.definition.adapter.pair_phone(@connection, phone, attempt:, request:, seq:)
    rescue Services::AdapterError => e
      # Only this request: another tab may have restarted or asked again
      # while this one was being sent.
      @connection.withdraw_phone_pairing_request!(attempt:, request:)
      return render json: { error: e.message }, status: :bad_gateway
    end
    audit(:request_service_phone_pairing, @connection, provider: @connection.provider)
    render json: pairing_json(@connection.reload), status: :accepted
  end

  private

  def set_connection
    @connection = current_account.service_connections.find_by_public_id!(params[:service_connection_id])
    raise ActiveRecord::RecordNotFound unless @connection.owner?(Current.user)

    response.headers["Cache-Control"] = "no-store"
  end

  def pairing_json(connection)
    json = { status: connection.status, qr: connection.current_pairing_qr }
    if connection.provider == "whatsapp"
      json[:attempt] = connection.pairing_attempt
      json[:phone] = connection.phone_pairing_state.slice("step", "error")
      json[:phone_code] = connection.current_pairing_phone_code
    end
    json
  end

  # Spaces, dots and dashes between digits are fine; anything else (a
  # bracketed trunk prefix, letters) is refused rather than guessed at.
  def normalized_phone(value)
    phone = value.to_s.strip.delete(" . -")
    phone if phone.match?(E164)
  end

end

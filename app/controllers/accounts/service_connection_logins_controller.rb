# The login steps of a Telegram connection, for the person who connected it
# (proposal 2026-10-11 §6.2). Only the owner: not account admins, other
# members or residents.
#
# The two-step password is forwarded to the connector inside this request
# and nowhere else: no column, no job, no log line (filter_parameters covers
# "passw"), no error report. The connector does SRP and drops it.
#
# The phone sign-in (for signing in on the phone itself, which cannot scan
# its own screen) gets the same treatment: the phone number and the code
# Telegram sends are forwarded and kept nowhere (filter_parameters covers
# "phone" and "code").
class Accounts::ServiceConnectionLoginsController < ApplicationController

  before_action :set_connection

  CODE_OUTCOMES = %w[accepted password_required code_invalid code_expired phone_unregistered flood_wait].freeze
  PHONE_OUTCOMES = %w[code_sent accepted password_required phone_invalid phone_banned unsupported flood_wait].freeze

  # GET .../login: the focused sign-in page Connect Telegram opens (the same
  # sign-in is also on the Integrations page's card).
  def show
    render inertia: "accounts/telegram_sign_in", props: {
      account: current_account.as_json,
      connection: @connection.as_connection_json(current_user: Current.user),
      integrations_url: account_integrations_path(current_account)
    }
  end

  # POST .../login/phone  { phone, generation }: sign in with the phone
  # number instead of the QR; Telegram sends a code to the account's app.
  def phone
    phone = params[:phone].to_s.strip
    if phone.empty? || phone.length > 40
      return render json: { error: "Enter the phone number, starting with + and the country code" }, status: :unprocessable_entity
    end

    generation = Integer(params[:generation].to_s, exception: false)
    return render json: { error: "Reload the page and try again" }, status: :unprocessable_entity if generation.nil?

    result = @connection.definition.adapter.request_code(@connection, phone, generation:)
    render json: phone_outcome(result)
  rescue Services::TelegramAdapter::StaleAttempt => e
    render json: { error: e.message }, status: :conflict
  rescue Services::AdapterError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  # POST .../login/code  { code, generation }: the code Telegram sent.
  def code
    unless @connection.status == "pairing" && @connection.login_state["step"] == "code"
      return render json: { error: "No code is being asked for" }, status: :conflict
    end

    code = params[:code].to_s.strip
    return render json: { error: "Enter the code" }, status: :unprocessable_entity if code.empty? || code.length > 64

    generation = Integer(params[:generation].to_s, exception: false)
    return render json: { error: "Reload the page and try again" }, status: :unprocessable_entity if generation.nil?

    result = @connection.definition.adapter.submit_code(@connection, code, generation:)
    render json: code_outcome(result)
  rescue Services::TelegramAdapter::StaleAttempt => e
    render json: { error: e.message }, status: :conflict
  rescue Services::AdapterError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  # POST .../login/password  { password, generation }
  #
  # generation is the attempt the owner's page is showing (from the pairing
  # endpoint); a password for an attempt that has since been restarted,
  # cancelled or finished is refused rather than joined to a newer one.
  def password
    unless @connection.status == "pairing" && @connection.login_state["step"] == "password"
      return render json: { error: "No password is being asked for" }, status: :conflict
    end

    password = params[:password].to_s
    return render json: { error: "Enter the password" }, status: :unprocessable_entity if password.empty?

    generation = Integer(params[:generation].to_s, exception: false)
    return render json: { error: "Reload the page and try again" }, status: :unprocessable_entity if generation.nil?

    result = @connection.definition.adapter.submit_password(@connection, password, generation:)
    render json: password_outcome(result)
  rescue Services::TelegramAdapter::StaleAttempt => e
    render json: { error: e.message }, status: :conflict
  rescue Services::AdapterError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  # POST .../login/restart: a new QR after an expiry, failure or cancel, or
  # to sign in again after Telegram logged the session out.
  def restart
    @connection.definition.adapter.start_pairing(@connection)
    audit(:restart_service_login, @connection, provider: @connection.provider)
    render json: state_json
  rescue Services::TelegramAdapter::StaleAttempt => e
    render json: { error: e.message }, status: :conflict
  rescue Services::AdapterError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  # POST .../login/cancel. The connection is marked cancelled (a new
  # generation) before the connector is told, and nothing is written after,
  # so a restart that happens meanwhile is never overwritten.
  def cancel
    if @connection.definition.adapter.cancel_login(@connection) == :not_pairing
      return render json: { error: "No sign-in to cancel" }, status: :conflict
    end

    render json: state_json
  end

  private

  def set_connection
    @connection = current_account.service_connections.find_by_public_id!(params[:service_connection_id])
    raise ActiveRecord::RecordNotFound unless @connection.owner?(Current.user) && @connection.provider == "telegram"

    response.headers["Cache-Control"] = "no-store"
  end

  def password_outcome(result)
    return { outcome: "not_configured" } if result == :not_configured

    outcome = result["outcome"].to_s
    outcome = "failed" unless %w[accepted password_invalid flood_wait].include?(outcome)
    { outcome:, retry_after: (result["retry_after"].to_i if outcome == "flood_wait") }.compact
  end

  def phone_outcome(result)
    return { outcome: "not_configured" } if result == :not_configured

    outcome = result["outcome"].to_s
    outcome = "failed" unless PHONE_OUTCOMES.include?(outcome)
    json = { outcome:, retry_after: (result["retry_after"].to_i if outcome == "flood_wait") }
    json[:login] = CommsEvents.code_step(result) if outcome == "code_sent"
    json[:generation] = @connection.login_generation
    json.compact
  end

  def code_outcome(result)
    return { outcome: "not_configured" } if result == :not_configured

    outcome = result["outcome"].to_s
    outcome = "failed" unless CODE_OUTCOMES.include?(outcome)
    { outcome:, retry_after: (result["retry_after"].to_i if outcome == "flood_wait") }.compact
  end

  def state_json
    @connection.reload
    { status: @connection.status, login: @connection.login_state, generation: @connection.login_generation }
  end

end

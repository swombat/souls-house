# The login steps of a Telegram connection, for the person who connected it
# (proposal 2026-10-11 §6.2). Only the owner: not account admins, other
# members or residents.
#
# The two-step password is forwarded to the connector inside this request
# and nowhere else: no column, no job, no log line (filter_parameters covers
# "passw"), no error report. The connector does SRP and drops it.
class Accounts::ServiceConnectionLoginsController < ApplicationController

  before_action :set_connection

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

  def state_json
    @connection.reload
    { status: @connection.status, login: @connection.login_state, generation: @connection.login_generation }
  end

end

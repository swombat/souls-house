# The login steps of a Telegram connection, for the person who connected it
# (proposal 2026-10-11 §6.2). Only the owner: not account admins, other
# members or residents.
#
# The two-step password is forwarded to the connector inside this request
# and nowhere else: no column, no job, no log line (filter_parameters covers
# "passw"), no error report. The connector does SRP and drops it.
class Accounts::ServiceConnectionLoginsController < ApplicationController

  before_action :set_connection

  # POST .../login/password  { password }
  def password
    unless @connection.status == "pairing" && @connection.login_state["step"] == "password"
      return render json: { error: "No password is being asked for" }, status: :conflict
    end

    password = params[:password].to_s
    return render json: { error: "Enter the password" }, status: :unprocessable_entity if password.empty?

    result = @connection.definition.adapter.submit_password(@connection, password)
    render json: password_outcome(result)
  rescue Services::AdapterError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  # POST .../login/restart: a new QR after an expiry, failure or cancel, or
  # to sign in again after Telegram logged the session out.
  def restart
    unless @connection.status.in?(%w[pairing reauthorizing])
      return render json: { error: "This connection is not waiting to sign in" }, status: :conflict
    end

    @connection.update!(status: "pairing") if @connection.status == "reauthorizing"
    @connection.definition.adapter.start_pairing(@connection)
    audit(:restart_service_login, @connection, provider: @connection.provider)
    render json: state_json
  rescue Services::AdapterError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  # POST .../login/cancel
  def cancel
    return render json: { error: "No sign-in to cancel" }, status: :conflict unless @connection.status == "pairing"

    @connection.definition.adapter.cancel_login(@connection)
    @connection.update!(connector_state: @connection.connector_state.to_h.merge("login" => { "error" => "cancelled" }))
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
    { status: @connection.status, login: @connection.login_state }
  end

end

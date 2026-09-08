class XIntegrationController < ApplicationController

  before_action :set_integration, except: %i[show create]

  def show
    integration = current_account.x_integration || current_account.build_x_integration

    render inertia: "settings/x_integration", props: {
      integration: integration_json(integration)
    }
  end

  def create
    state = SecureRandom.hex(32)
    code_verifier = SecureRandom.urlsafe_base64(32)
    code_challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(code_verifier), padding: false)

    session[:x_oauth_state] = state
    session[:x_oauth_state_expires_at] = 10.minutes.from_now.to_i
    session[:x_oauth_code_verifier] = code_verifier

    integration = current_account.x_integration || current_account.create_x_integration!

    redirect_to integration.authorization_url(state: state, redirect_uri: x_redirect_uri, code_challenge: code_challenge),
                allow_other_host: true
  end

  def callback
    if params[:error]
      redirect_to x_integration_path, alert: "Authorization was denied"
      return
    end

    expected_state = session.delete(:x_oauth_state)
    expires_at = session.delete(:x_oauth_state_expires_at)
    code_verifier = session.delete(:x_oauth_code_verifier)

    unless expected_state == params[:state] && Time.current.to_i < expires_at.to_i
      redirect_to x_integration_path, alert: "Invalid or expired authorization"
      return
    end

    unless @integration
      redirect_to x_integration_path, alert: "No integration found"
      return
    end

    @integration.exchange_code!(code: params[:code], redirect_uri: x_redirect_uri, code_verifier: code_verifier)

    redirect_to x_integration_path, notice: "X/Twitter connected successfully"
  rescue XApi::Error => e
    redirect_to x_integration_path, alert: "Failed to connect: #{e.message}"
  end

  def update
    redirect_to x_integration_path and return unless @integration

    @integration.update!(integration_params)
    redirect_to x_integration_path, notice: "Settings updated"
  end

  def destroy
    @integration&.disconnect!

    redirect_to x_integration_path, notice: "X/Twitter disconnected"
  end

  private

  def set_integration
    @integration = current_account.x_integration
  end

  def x_redirect_uri
    base = Rails.configuration.x.public_url || request.base_url
    "#{base}/x_integration/callback"
  end

  def integration_params
    params.require(:x_integration).permit(:enabled)
  end

  def integration_json(integration)
    {
      id: integration.id,
      enabled: integration.enabled?,
      connected: integration.connected?,
      x_username: integration.x_username
    }
  end

end

class XIntegrationController < ApplicationController

  before_action :set_integration, except: %i[show create app]
  before_action :require_manager, except: :show

  def show
    integration = current_account.x_integration || current_account.build_x_integration

    render inertia: "settings/x_integration", props: {
      account_id: current_account.to_param,
      integration: integration_json(integration),
      can_manage: current_account.service_credentials_manageable_by?(Current.user),
      recent_posts: integration.persisted? ? integration.tweet_logs.includes(:agent).recent.limit(20).map { |log| post_json(log) } : []
    }
  end

  def create
    state = SecureRandom.hex(32)
    code_verifier = SecureRandom.urlsafe_base64(32)
    code_challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(code_verifier), padding: false)

    session[:x_oauth_state] = state
    session[:x_oauth_state_expires_at] = 10.minutes.from_now.to_i
    session[:x_oauth_code_verifier] = code_verifier
    session[:x_oauth_account_id] = current_account.to_param

    integration = current_account.x_integration || current_account.create_x_integration!(enabled: false)
    unless integration.app_available?
      redirect_to x_page_path, alert: "Add this account's X app before connecting"
      return
    end
    # The authorisation is for the app as it is now; the callback's tokens
    # are kept only if the app hasn't changed (or been removed) meanwhile.
    session[:x_oauth_app_generation] = integration.app_generation

    redirect_to integration.authorization_url(state: state, redirect_uri: x_redirect_uri, code_challenge: code_challenge),
                allow_other_host: true
  end

  def callback
    if params[:error]
      redirect_to x_page_path, alert: "Authorization was denied"
      return
    end

    expected_state = session.delete(:x_oauth_state)
    expires_at = session.delete(:x_oauth_state_expires_at)
    code_verifier = session.delete(:x_oauth_code_verifier)
    session.delete(:x_oauth_account_id)
    app_generation = session.delete(:x_oauth_app_generation)

    unless expected_state == params[:state] && Time.current.to_i < expires_at.to_i
      redirect_to x_page_path, alert: "Invalid or expired authorization"
      return
    end

    unless @integration
      redirect_to x_page_path, alert: "No integration found"
      return
    end

    @integration.exchange_code!(code: params[:code], redirect_uri: x_redirect_uri, code_verifier: code_verifier, app_generation: app_generation)

    redirect_to x_page_path, notice: "X/Twitter connected successfully"
  rescue XApi::Error => e
    redirect_to x_page_path, alert: "Failed to connect: #{e.message}"
  end

  def update
    redirect_to x_page_path and return unless @integration

    @integration.update!(integration_params)
    redirect_to x_page_path, notice: "Settings updated"
  end

  # The account's own X app. Saving a different one, or removing it,
  # disconnects the handle: its tokens belong to the app that issued them.
  def app
    integration = current_account.x_integration || current_account.create_x_integration!(enabled: false)

    if request.delete?
      integration.remove_own_app!
      redirect_to x_page_path, notice: "X app removed; the handle is disconnected"
    else
      app_params = params.require(:x_app).permit(:client_id, :client_secret)
      integration.set_own_app!(client_id: app_params[:client_id], client_secret: app_params[:client_secret])
      redirect_to x_page_path, notice: "X app saved. Connect the handle to finish."
    end
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    redirect_to x_page_path, alert: e.message
  end

  def destroy
    @integration&.disconnect!

    redirect_to x_page_path, notice: "X/Twitter disconnected"
  end

  private

  # The X page is reached from an account's integrations list with
  # ?account_id=…; X's OAuth callback carries no account, so the account the
  # connection was started from is kept in the session for that one request.
  def current_account
    return super unless action_name == "callback" && params[:account_id].blank? && session[:x_oauth_account_id].present?

    @current_account ||= find_current_user_account!(session[:x_oauth_account_id])
  end

  def x_page_path
    x_integration_path(account_id: current_account.to_param)
  end

  def set_integration
    @integration = current_account.x_integration
  end

  # Connecting, switching posting on or off and disconnecting decide what
  # residents may publish under the account's handle: account admins only.
  def require_manager
    return if current_account.service_credentials_manageable_by?(Current.user)

    redirect_to x_page_path, alert: "Only account admins can change the X connection"
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
      x_username: integration.x_username,
      app_source: integration.app_source,
      house_app_allowed: integration.house_app_allowed?,
      house_app_reason: integration.house_app_reason,
      own_app: integration.own_app?,
      own_client_id: integration.client_id,
      callback_url: x_redirect_uri,
      outcome_unknown_count: integration.persisted? ? integration.tweet_logs.outcome_unknown.count : 0
    }
  end

  def post_json(log)
    log.as_post_json.merge(resident_name: log.agent&.name)
  end

end

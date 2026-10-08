module ApiAuthentication

  extend ActiveSupport::Concern

  # One API, several ways to authenticate. A bearer is either an API key
  # (a person's account key, or a resident key) or a native-app OAuth access
  # token. Each resolves to who is acting (a person or a resident) and the
  # account the request acts in.
  #
  # An OAuth token belongs to a person, not an account. Its account is the one
  # the request names with account_id, checked against the person's current
  # confirmed memberships on every request, and otherwise their default
  # account. Rooms it may act in span every account the person belongs to.

  included do
    before_action :authenticate_api_key!
  end

  private

  def authenticate_api_key!
    token = request.headers["Authorization"]&.delete_prefix("Bearer ")
    @current_api_key = ApiKey.authenticate(token)

    if @current_api_key
      @current_api_key.touch_usage!(request.remote_ip)
      Current.api_key = @current_api_key
      Current.api_user = @current_api_key.user
      Current.api_agent = @current_api_key.agent
      return
    end

    @current_app_session = AppAccessTokenAuthenticator.authenticate(request)
    unless @current_app_session
      render json: { error: "Invalid or missing API key" }, status: :unauthorized
      return
    end

    user = @current_app_session.user
    @current_app_account = if params[:account_id].present?
      begin
        user.confirmed_accounts.find(params[:account_id])
      rescue ActiveRecord::RecordNotFound, Hashids::InputError
        nil
      end
    else
      user.default_account.then { |account| account if account && user.confirmed_accounts.exists?(account.id) }
    end
    unless @current_app_account
      render json: { error: "Not found" }, status: :not_found
      return
    end

    Current.api_user = user
    Current.api_agent = nil
  end

  def current_api_user
    @current_api_key ? @current_api_key.user : @current_app_session&.user
  end

  def current_api_account
    @current_api_key ? @current_api_key.account : @current_app_account
  end

  def current_api_agent
    Current.api_agent
  end

  # True when the bearer is a native-app OAuth token rather than an API key.
  def app_token_request?
    @current_app_session.present?
  end

  # Rooms a person may act in. An account key reaches its account's rooms; an
  # OAuth token reaches every account the person currently belongs to, or only
  # the one named by account_id.
  def human_chats
    return current_api_account.chats unless app_token_request?
    return current_api_account.chats if params[:account_id].present?

    Chat.where(account_id: current_api_user.confirmed_accounts.select(:id))
  end

end

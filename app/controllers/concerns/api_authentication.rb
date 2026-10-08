module ApiAuthentication

  extend ActiveSupport::Concern

  # One API, several ways to authenticate. A bearer is either an API key
  # (a person's account key, or a resident key) or a native-app OAuth access
  # token. Each resolves to who is acting (a person or a resident) and, when a
  # request needs one, the account it acts in.
  #
  # An OAuth token belongs to a person, not an account. Its account is resolved
  # only when an action needs one: the account account_id names (a current,
  # confirmed membership of an enabled account, else 404), otherwise their
  # default enabled account. Rooms it may act in span every enabled account the
  # person belongs to, so an unusable default never blocks the others.

  class NoAccount < StandardError; end

  included do
    before_action :authenticate_api_key!
    rescue_from NoAccount do
      render json: { error: "Not found" }, status: :not_found
    end
  end

  private

  def authenticate_api_key!
    unless account_id_param_scalar?
      render json: { error: "account_id must be a single account id" }, status: :unprocessable_entity
      return
    end

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

    Current.api_user = @current_app_session.user
    Current.api_agent = nil
  end

  def account_id_param_scalar?
    !params.key?(:account_id) || params[:account_id].is_a?(String) || params[:account_id].is_a?(Integer)
  end

  def current_api_user
    @current_api_key ? @current_api_key.user : @current_app_session&.user
  end

  # The account the request acts in. For an OAuth token this is resolved on
  # first use, so requests that span accounts never depend on it.
  def current_api_account
    return @current_api_key.account if @current_api_key
    return unless @current_app_session

    @current_app_account ||= resolve_app_account
  end

  def resolve_app_account
    accounts = current_api_user.confirmed_accounts
    account = if params[:account_id].present?
      begin
        accounts.find(params[:account_id].to_s)
      rescue ActiveRecord::RecordNotFound, Hashids::InputError
        nil
      end
    else
      default_id = current_api_user.default_account_id
      (default_id && accounts.find_by(id: default_id)) ||
        accounts.merge(Membership.order(:created_at)).first
    end
    account || raise(NoAccount)
  end

  def current_api_agent
    Current.api_agent
  end

  # True when the bearer is a native-app OAuth token rather than an API key.
  def app_token_request?
    @current_app_session.present?
  end

  # Rooms a person may act in. An account key reaches its account's rooms; an
  # OAuth token reaches every enabled account the person currently belongs to,
  # or only the one named by account_id.
  def human_chats
    return current_api_account.chats unless app_token_request?
    return current_api_account.chats if params[:account_id].present?

    Chat.where(account_id: current_api_user.confirmed_accounts.select(:id))
  end

end

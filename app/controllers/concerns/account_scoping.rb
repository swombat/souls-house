module AccountScoping

  extend ActiveSupport::Concern

  included do
    helper_method :current_account, :current_membership
    before_action :set_current_account
  end

  private

  def current_account
    @current_account ||= if params[:account_id]
      find_current_user_account!(params[:account_id])
    else
      Current.user&.default_account
    end
  end

  # The account's conversations this person may see: private ones only if
  # they are in them (Chat.visible_to). Every human-facing chat lookup goes
  # through here, so a chat outside it is simply not found (404).
  def visible_chats
    visible_chats.visible_to(Current.user)
  end

  def current_membership
    @current_membership ||= if current_account && Current.user
      Current.user.confirmed_memberships.find_by(account: current_account)
    end
  end

  def require_account
    redirect_to root_path, alert: "You don't have access to an account" unless current_account
  end

  def require_account_manager!
    return if current_account&.manageable_by?(Current.user)

    deny_account_access!("You don't have permission to manage this account")
  end

  def require_account_owner!
    return if current_account&.owned_by?(Current.user)

    deny_account_access!("You don't have permission to change this account")
  end

  def set_current_account
    Current.account = current_account
  end

  def authorize_account_resource(resource)
    return unless resource.respond_to?(:account) # Resources without account are not scoped to an account

    return if resource&.account&.accessible_by?(Current.user)

    deny_account_access!("You don't have access to this resource")
  end

  def find_current_user_account!(account_id)
    return unless Current.user
    return Account.find(account_id) if Current.user.site_admin

    Current.user.confirmed_accounts.find(account_id)
  end

  def deny_account_access!(message)
    respond_to do |format|
      format.json { render json: { error: message }, status: :forbidden }
      format.any { redirect_back_or_to account_access_denied_path, alert: message }
    end
  end

  def account_access_denied_path
    current_account ? account_path(current_account) : root_path
  end

end

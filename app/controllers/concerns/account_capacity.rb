module AccountCapacity

  extend ActiveSupport::Concern

  private

  def require_account_capacity
    resume_session # Signup also permits anonymous requests; still recognise an admin session.
    unless Setting.instance.account_creation_allowed?
      redirect_to root_path, alert: Account::ACCOUNT_LIMIT_MESSAGE
    end
  end

end

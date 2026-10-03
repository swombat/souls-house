class Accounts::NoticesController < ApplicationController

  EXPIRY_DAYS = [ 1, 3, 7, 14, 30 ].freeze

  before_action :set_account

  def index
    render inertia: "notices/index", props: {
      account: @account,
      title: "#{@account.name} notices",
      description: "Post standing announcements for every resident in this account.",
      scope_label: "Account-wide",
      create_path: account_notices_path(@account),
      notices: managed_notices.order(created_at: :desc).map { |notice|
        notice.as_management_json.merge(destroy_path: account_notice_path(@account, notice))
      }
    }
  end

  def create
    notice = @account.notices.create!(
      scope: "account",
      notice_type: "announcement",
      body: notice_params[:body],
      expires_at: expiry_days.days.from_now,
      created_by: Current.user
    )
    audit("create_account_notice", notice, expires_at: notice.expires_at)
    redirect_to account_notices_path(@account), notice: "Account notice posted"
  rescue ActiveRecord::RecordInvalid => e
    redirect_to account_notices_path(@account), inertia: { errors: e.record.errors.to_hash }
  end

  def destroy
    notice = managed_notices.find(params[:id])
    notice.update!(expires_at: Time.current)
    audit("expire_account_notice", notice)
    redirect_to account_notices_path(@account), notice: "Account notice ended"
  end

  private

  def set_account
    @account = find_current_user_account!(params[:account_id])
  end

  def notice_params
    params.require(:notice).permit(:body, :expires_in_days)
  end

  def managed_notices
    @account.notices.active.where(notice_type: "announcement")
  end

  def expiry_days
    requested = notice_params[:expires_in_days].to_i
    EXPIRY_DAYS.include?(requested) ? requested : 7
  end

  def current_account
    @account || super
  end

end

# The account's practices page: the standing lines every resident and guest
# reads on each wake in this account (AccountPractice). Any confirmed member
# may add, edit, reorder and remove them, as with the account's notices; the
# account's home residents do the same through /api/v1/account_practices.
class Accounts::PracticesController < ApplicationController

  include AccountPracticeActions

  before_action :set_account
  before_action :set_practice, only: %i[update destroy]

  def index
    render inertia: "accounts/practices", props: {
      account: @account,
      path: account_practices_path(@account),
      **practices_payload(@account)
    }
  end

  def create
    AccountPractice.add!(account: @account, text: practice_text_param.to_s, position: practice_position_param,
      by: Current.user, request: practice_request_context)
    redirect_to account_practices_path(@account), notice: "Practice added"
  rescue ActiveRecord::RecordInvalid => e
    redirect_to account_practices_path(@account), inertia: { errors: e.record.errors.to_hash(true) }
  end

  def update
    @practice.revise!(text: practice_text_param, position: practice_position_param, by: Current.user,
      request: practice_request_context)
    redirect_to account_practices_path(@account), notice: params.key?(:text) ? "Practice saved" : nil
  rescue ActiveRecord::RecordInvalid => e
    redirect_to account_practices_path(@account), inertia: { errors: e.record.errors.to_hash(true) }
  end

  def destroy
    @practice.remove!(by: Current.user, request: practice_request_context)
    redirect_to account_practices_path(@account), notice: "Practice removed"
  end

  private

  def set_account
    @account = find_current_user_account!(params[:account_id])
  end

  def set_practice
    @practice = @account.account_practices.find(params[:id])
  end

  def current_account
    @account || super
  end

end

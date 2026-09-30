class AccountsController < ApplicationController

  include AccountCapacity
  before_action :require_account_capacity, only: %i[ new create ]

  before_action :set_account, except: %i[new create]

  def new
    render inertia: "accounts/new"
  end

  def create
    account = nil

    Account.transaction do
      account = Account.create!(create_account_params)
      account.add_user!(Current.user, role: "owner", skip_confirmation: true)
    end

    audit(:create_account, account, name: account.name, account_type: account.account_type)
    redirect_to account_chats_path(account), notice: "Account created"
  rescue ActiveRecord::RecordInvalid => e
    redirect_to new_account_path, inertia: { errors: e.record.errors.to_hash.presence || e.message }
  end

  def show
    render inertia: "accounts/show", props: account_show_props
  end

  def edit
    if params[:convert].present?
      render inertia: "accounts/convert_confirmation", props: edit_conversion_props
    else
      render inertia: "accounts/edit", props: {
        account: @account
      }
    end
  end

  def update
    handle_account_conversion || update_account_settings
  rescue ActiveRecord::RecordInvalid => e
    redirect_to @account, alert: e.message
  end

  private

  def account_show_props
    {
      account: @account,
      can_be_personal: @account.can_be_personal?,
      members: account_members_json,
      can_manage: @account.manageable_by?(Current.user),
      current_user_id: Current.user.id
    }
  end

  def edit_conversion_props
    {
      account: @account,
      can_be_personal: @account.can_be_personal?,
      members_count: @account.personal? ? 1 : @account.memberships.count
    }
  end

  def account_members_json
    return [] if @account.personal?

    @account.members_with_details.map { |member| member.as_json(current_user: Current.user) }
  end

  def handle_account_conversion
    case params[:convert_to]
    when "personal"
      convert_to_personal
    when "team"
      convert_to_team
    else
      false
    end
  end

  def convert_to_personal
    @account.make_personal!
    audit(:convert_to_personal, @account, name: @account.name)
    redirect_to @account, notice: "Converted to personal account"
    true
  end

  def convert_to_team
    old_name = @account.name
    @account.make_team!(params[:account][:name])
    audit(:convert_to_team, @account, from: old_name, to: @account.name)
    redirect_to @account, notice: "Converted to team account"
    true
  end

  def update_account_settings
    return unless @account.update!(account_params)

    audit_account_changes if account_has_meaningful_changes?
    redirect_to @account, notice: "Account updated"
  end

  def account_has_meaningful_changes?
    @account.saved_changes.except(:updated_at).any?
  end

  def audit_account_changes
    audit_with_changes(:update_account_settings, @account)
  end

  def set_account
    @account = find_current_user_account!(params[:id])
  end

  def account_params
    params.require(:account).permit(:name)
  end

  def create_account_params
    params.require(:account).permit(:name, :account_type)
  end

  def current_account
    @current_account ||= @account || (params[:id] ? find_current_user_account!(params[:id]) : super)
  end

end

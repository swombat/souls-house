class Admin::AccountsController < ApplicationController

  # Skip account scoping for admin controllers - admins can see all accounts
  skip_before_action :set_current_account

  before_action :require_site_admin
  before_action :set_account, only: %i[disable enable convert shared_ai_credentials refresh_storage]

  def index
    @accounts = Account.includes(:owner, memberships: :user)
                       .order(created_at: :desc)

    # Admin can view any account, not just ones they belong to
    # So we bypass the AccountScoping concern's current_account method
    selected_account_id = params[:account_id]
    @selected_account = Account.includes(memberships: :user).find(selected_account_id) if selected_account_id.present?

    render inertia: "admin/accounts", props: {
      accounts: accounts_json,
      selected_account: @selected_account ? selected_account_json(@selected_account) : nil
    }
  end

  def disable
    @account.disable!
    audit(:admin_disable_account, @account, account_id: @account.id, name: @account.name)
    redirect_to admin_accounts_path(account_id: @account), notice: "Account disabled"
  end

  def enable
    @account.enable!
    audit(:admin_enable_account, @account, account_id: @account.id, name: @account.name)
    redirect_to admin_accounts_path(account_id: @account), notice: "Account enabled"
  end

  def convert
    case params[:account_type]
    when "team"
      convert_to_team
    when "personal"
      convert_to_personal
    else
      redirect_to admin_accounts_path(account_id: @account), alert: "Unknown account type"
    end
  end

  def shared_ai_credentials
    enabled = ActiveModel::Type::Boolean.new.cast(params.require(:account).require(:use_system_ai_credentials))
    @account.update!(use_system_ai_credentials: enabled)
    AccountAgentCredentialsRefreshJob.perform_later(@account.id)
    audit(
      :admin_update_shared_ai_credentials,
      @account,
      account_id: @account.id,
      use_system_ai_credentials: enabled
    )
    redirect_to admin_accounts_path(account_id: @account), notice: "Shared AI credential fallback updated"
  end

  def refresh_storage
    @account.agents.hosted.find_each do |agent|
      AgentStorageUsageJob.perform_later(agent.id)
    end
    audit(:admin_refresh_account_storage, @account, account_id: @account.id)
    redirect_to admin_accounts_path(account_id: @account), notice: "Storage measurement queued. Refresh the overview shortly."
  end

  private

  def accounts_json
    @accounts.as_json(
      include: [ :owner ],
      methods: [ :users_count, :members_count, :active, :disabled ]
    )
  end

  def selected_account_json(account)
    account.as_json(
      include: [ :owner, users: { methods: [ :full_name ] } ],
      methods: [ :users_count, :members_count, :active, :disabled ]
    ).merge(
      "use_system_ai_credentials" => account.use_system_ai_credentials?,
      "usage" => Admin::AccountUsageReport.new(account).call,
      "memberships" => account.memberships.map { |membership| membership_json(membership) }
    )
  end

  def membership_json(membership)
    membership.as_json.merge(
      "display_name" => membership.display_name,
      "status" => membership.status,
      "email_address" => membership.email_address,
      "full_name" => membership.full_name,
      "confirmed" => membership.confirmed?,
      "user" => membership.user.as_json(only: [ :id, :email_address ], methods: [ :full_name ])
    )
  end

  def convert_to_team
    name = params.dig(:account, :name).presence || @account.name
    @account.make_team!(name)
    audit(:admin_convert_account_to_team, @account, account_id: @account.id, name: @account.name)
    redirect_to admin_accounts_path(account_id: @account), notice: "Account converted to team"
  end

  def convert_to_personal
    if @account.can_be_personal?
      @account.make_personal!
      audit(:admin_convert_account_to_personal, @account, account_id: @account.id, name: @account.name)
      redirect_to admin_accounts_path(account_id: @account), notice: "Account converted to personal"
    else
      redirect_to admin_accounts_path(account_id: @account),
        alert: "Team accounts can only become personal accounts after they have exactly one member"
    end
  end

  def set_account
    @account = Account.find(params[:id])
  end

  def require_site_admin
    redirect_to root_path unless Current.user&.is_site_admin?
  end

  # Override AccountScoping's current_account method for admin controllers
  # Admin controllers should not use account scoping
  def current_account
    nil
  end

end

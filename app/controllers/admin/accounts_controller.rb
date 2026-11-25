class Admin::AccountsController < ApplicationController

  # Skip account scoping for admin controllers - admins can see all accounts
  skip_before_action :set_current_account

  before_action :require_site_admin
  before_action :set_account, only: %i[disable enable convert shared_ai_credentials founding billing_required granted_plan field_swarm field_tweets_house_key house_eleven_labs_key x_posting_house_app refresh_storage]

  def index
    @accounts = Account.includes(:owner, memberships: :user)
                       .order(created_at: :desc)

    render inertia: "admin/accounts", props: {
      accounts: accounts_json,
      selected_account: -> {
        # Admin can view any account, not just ones they belong to.
        if params[:account_id].present?
          selected_account_json(Account.includes(memberships: :user).find(params[:account_id]))
        end
      }
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

  def founding
    founding = ActiveModel::Type::Boolean.new.cast(params.require(:account).require(:founding))
    @account.update!(founding: founding)
    SiteDashboard.expire_cache!
    audit(:admin_update_founding_account, @account, account_id: @account.id, founding: founding)
    redirect_back_or_to admin_accounts_path(account_id: @account),
      notice: founding ? "Marked as a founding account" : "No longer a founding account"
  end

  # Whether new residents in this account need a plan. Set at account creation
  # from the site's billing switch; residents the account already has stay on
  # the house either way.
  def billing_required
    required = ActiveModel::Type::Boolean.new.cast(params.require(:account).require(:billing_required))
    @account.update!(billing_required: required)
    audit(:admin_update_account_billing_required, @account, account_id: @account.id, billing_required: required)
    redirect_back_or_to admin_accounts_path(account_id: @account),
      notice: required ? "New residents in this account now need a plan" : "New residents in this account are on the house"
  end

  # A plan given by the house, with nothing to pay (Account#given_plan).
  # Blank removes the grant. Everything the plan decides (members, sub-agents,
  # the plan offer, ElevenLabs, swarm searches, transcription hours) reads
  # Account#plan when it is needed, so nothing else has to follow. A paid plan
  # line stays on the account's bill either way; this never touches Stripe.
  def granted_plan
    value = params.require(:account).fetch(:granted_plan, nil).presence
    if value && !value.in?(Billing::AccountPlan::IDS)
      raise ActionController::BadRequest, "Unknown plan #{value.to_s.truncate(40).inspect}"
    end

    before = @account.granted_plan
    @account.update!(granted_plan: value)
    audit(:admin_update_account_granted_plan, @account, account_id: @account.id, granted_plan_before: before,
      granted_plan: value, plan_now: @account.plan.id)
    redirect_back_or_to admin_accounts_path(account_id: @account), notice: granted_plan_notice(value)
  end

  def refresh_storage
    @account.agents.hosted.find_each do |agent|
      AgentStorageUsageJob.perform_later(agent.id)
    end
    audit(:admin_refresh_account_storage, @account, account_id: @account.id)
    redirect_to admin_accounts_path(account_id: @account), notice: "Storage measurement queued. Refresh the overview shortly."
  end

  # Field swarm search (FieldSwarm): a test feature, off for every account
  # until turned on here.
  def field_swarm
    enabled = ActiveModel::Type::Boolean.new.cast(params.require(:account).require(:field_swarm_enabled))
    @account.update!(field_swarm_enabled: enabled)
    audit(:admin_update_field_swarm, @account, account_id: @account.id, field_swarm_enabled: enabled)
    redirect_back_or_to admin_accounts_path(account_id: @account),
      notice: enabled ? "Field swarm search turned on" : "Field swarm search turned off"
  end

  # The house's TwitterAPI.io key, for an account without its own
  # integration (FieldTweets.funding_for). Off for every account until
  # turned on here; the house ceilings still apply.
  def field_tweets_house_key
    enabled = ActiveModel::Type::Boolean.new.cast(params.require(:account).require(:field_tweets_house_key))
    @account.update!(field_tweets_house_key: enabled)
    FieldTweets.integration_changed!(@account)
    audit(:admin_update_field_tweets_house_key, @account, account_id: @account.id, field_tweets_house_key: enabled)
    redirect_back_or_to admin_accounts_path(account_id: @account),
      notice: enabled ? "This account's tweet streams may use the house TwitterAPI.io key" : "This account's tweet streams no longer use the house key"
  end

  # The house's ElevenLabs key, for an account without its own
  # (SpeechEngine.eleven_labs_key). Off for every account until turned on
  # here; the plan rule still applies, and the account's own key pays first.
  def house_eleven_labs_key
    enabled = ActiveModel::Type::Boolean.new.cast(params.require(:account).require(:house_eleven_labs_key))
    @account.update!(house_eleven_labs_key: enabled)
    audit(:admin_update_house_eleven_labs_key, @account, account_id: @account.id, house_eleven_labs_key: enabled)
    redirect_back_or_to admin_accounts_path(account_id: @account),
      notice: enabled ? "This account may speak on the house ElevenLabs key" : "This account no longer speaks on the house ElevenLabs key"
  end

  # The house X app, for an account without a site admin among its members
  # (accounts with one use it without this). Withdrawing it disconnects an
  # X handle connected through the house app; an account's own app is
  # untouched.
  def x_posting_house_app
    enabled = ActiveModel::Type::Boolean.new.cast(params.require(:account).require(:x_posting_house_app))
    @account.update!(x_posting_house_app: enabled)
    XIntegration.house_app_access_changed!(@account) unless enabled
    audit(:admin_update_x_posting_house_app, @account, account_id: @account.id, x_posting_house_app: enabled)
    redirect_back_or_to admin_accounts_path(account_id: @account),
      notice: enabled ? "This account may post to X through the house X app" : "This account no longer posts through the house X app"
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
      "field_swarm_enabled" => account.field_swarm_enabled?,
      "field_tweets_house_key" => account.field_tweets_house_key?,
      "field_tweets_own_integration" => FieldTweets.integration_for(account).present?,
      "house_eleven_labs_key" => account.house_eleven_labs_key?,
      "eleven_labs_own_key" => account.eleven_labs_api_key.present?,
      "house_eleven_labs_characters_30_days" => SpeechCharge.on_house_key.where(account:, created_at: 30.days.ago..).sum(:characters),
      "x_posting_house_app" => account.x_posting_house_app?,
      "x_posting_site_admin_member" => account.includes_site_admin?,
      "x_posting_own_app" => account.x_integration&.own_app? || false,
      "field_swarm" => field_swarm_costs(account),
      "plan" => plan_json(account),
      "usage" => Admin::AccountUsageReport.new(account).call,
      "memberships" => account.memberships.map { |membership| membership_json(membership) }
    )
  end

  # What swarm search has cost, for this account and the whole house, so the
  # test can be judged on its spend.
  def field_swarm_costs(account)
    since = 30.days.ago
    {
      account_30_days: FieldSwarmSearch.totals(FieldSwarmSearch.where(account: account, created_at: since..)),
      account_all_time: FieldSwarmSearch.totals(FieldSwarmSearch.where(account: account)),
      house_30_days: FieldSwarmSearch.totals(FieldSwarmSearch.where(created_at: since..)),
      house_all_time: FieldSwarmSearch.totals,
      enabled_accounts: Account.where(field_swarm_enabled: true).count
    }
  end

  # Why the account's plan is what it is: the grant, plan codes and a paid
  # plan line, each as the account has it now.
  def plan_json(account)
    subscription = account.live_plan_subscription
    codes = account.billing_code_redemptions.live.includes(:billing_code).where("effect LIKE 'plan:%'").order(:id)
    {
      "id" => account.plan.id,
      "name" => account.plan.name,
      "source" => account.plan_source,
      "granted_plan" => account.granted_plan,
      "plans" => Billing::AccountPlan.all.map { |plan| { "id" => plan.id, "name" => plan.name } },
      "subscription" => subscription && {
        "plan" => subscription.plan,
        "plan_name" => subscription.plan_record&.name,
        "status" => subscription.stripe_status,
        "in_force" => subscription.in_force?
      },
      "plan_codes" => codes.map do |redemption|
        { "code" => redemption.billing_code.code, "plan" => BillingCode.plan_of(redemption.effect)&.id,
          "plan_name" => BillingCode.plan_of(redemption.effect)&.name }
      end,
      "plan_to_pay_for" => account.plan_to_pay_for&.id
    }
  end

  def granted_plan_notice(value)
    return "#{@account.name} no longer has a plan from the house. Its plan is now #{@account.plan.name}." if value.nil?

    "#{@account.name} now has #{Billing::AccountPlan.find(value).name} from the house. Its plan is #{@account.plan.name}."
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

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
      # The name is edited in place on the General tab.
      redirect_to account_path(@account)
    end
  end

  def update
    handle_account_conversion || update_account_settings
  rescue ActiveRecord::RecordInvalid => e
    redirect_to settings_return_path, alert: e.message
  end

  private

  def account_show_props
    {
      account: @account,
      can_be_personal: @account.can_be_personal?,
      members_count: @account.personal? ? 1 : @account.memberships.count,
      can_manage: @account.manageable_by?(Current.user),
      logo_colour_options: Account::LOGO_COLOURS
    }
  end

  def edit_conversion_props
    {
      account: @account,
      can_be_personal: @account.can_be_personal?,
      members_count: @account.personal? ? 1 : @account.memberships.count
    }
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
    return redirect_to(settings_return_path, alert: SPEECH_ENGINE_NOT_OFFERED) if choosing_unoffered_engine?
    return unless @account.update!(account_params)

    audit_account_changes if account_has_meaningful_changes?
    redirect_to settings_return_path, notice: "Account updated"
  end

  # The settings on the Features tab, which save here too.
  FEATURE_SETTINGS = %w[
    resident_handoff_cap stalled_thread_wake_cap telegram_bot_wake_limit reflexes_enabled voice_mode_enabled speech_engine
    eleven_labs_api_key plan_offer_enabled show_chat_codes show_room_chat_counts
  ].freeze

  # A Features change goes back to Features rather than to General, where
  # only the name is edited now. Only fields this person may change count, so
  # an ignored Features field from a non-manager doesn't pick the page.
  def settings_return_path
    submitted = params[:account]
    return account_path(@account) unless submitted.respond_to?(:keys) && @account.manageable_by?(Current.user)

    submitted.keys.map(&:to_s).intersect?(FEATURE_SETTINGS) ? account_features_path(@account) : account_path(@account)
  end

  def account_has_meaningful_changes?
    @account.saved_changes.except(:updated_at).any?
  end

  def audit_account_changes
    audit_with_changes(:update_account_settings, @account)
  end

  SPEECH_ENGINE_NOT_OFFERED = "ElevenLabs isn't offered as a voice engine on this site just now, so this account stays on Phonon."

  # ElevenLabs can be chosen only while the site leaves the engine to each
  # account (SpeechEngine); going back to Phonon is always allowed.
  def choosing_unoffered_engine?
    params.dig(:account, :speech_engine) == SpeechEngine::ELEVENLABS &&
      @account.speech_engine != SpeechEngine::ELEVENLABS && !SpeechEngine.choice_offered?
  end

  def set_account
    @account = find_current_user_account!(params[:id])
  end

  # The resident handoff cap (MessageHandoff), the stalled-thread wake cap
  # (StalledThreadWake), the Telegram bot answer limit
  # (TelegramSubscription#bot_wake_limit), the reflexes switch
  # (ReflexCheck) and the voice mode switch (VoiceMode) are changed only by
  # someone who can manage the account, as are showing conversation codes
  # and the conversation totals in the room menus.
  def account_params
    permitted = [ :name ]
    if @account.manageable_by?(Current.user)
      permitted.push(*FEATURE_SETTINGS.map(&:to_sym))
    end
    params.require(:account).permit(permitted)
  end

  def create_account_params
    params.require(:account).permit(:name, :account_type)
  end

  def current_account
    @current_account ||= @account || (params[:id] ? find_current_user_account!(params[:id]) : super)
  end

end

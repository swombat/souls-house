class UsersController < ApplicationController

  def edit
    render inertia: "user/edit", props: {
      timezones: timezone_options,
      colour_options: Profile::VALID_CHAT_COLOURS,
      accounts: Current.user.confirmed_accounts.map { |account| { id: account.to_param, name: account.name } },
      default_account_key: Current.user.default_account_key
    }
  end

  def update
    update_user_successfully || handle_update_failure
  end

  private

  def timezone_options
    ActiveSupport::TimeZone.all.map { |tz| { value: tz.name, label: tz.to_s } }
  end

  def update_user_successfully
    # Handle profile attributes in both nested and direct format
    params_for_user, params_for_profile = User.split_settings_params(user_params)
    return false unless Current.user.update_settings(params_for_user, params_for_profile)

    audit_user_changes
    set_theme_cookie if theme_changed?
    respond_with_update_success
    true
  end

  def handle_update_failure
    respond_with_update_errors
  end

  def audit_user_changes
    audit_with_changes(Current.user.settings_audit_action(avatar_updated: avatar_being_updated?), Current.user)
  end

  def avatar_being_updated?
    user_params[:avatar].present? || (user_params[:profile_attributes] && user_params[:profile_attributes][:avatar].present?)
  end

  def respond_with_update_success
    inertia_request? ?
      redirect_with_inertia_flash(:success, "Settings updated successfully", edit_user_path) :
      render(json: { success: true }, status: :ok)
  end

  def respond_with_update_errors
    inertia_request? ?
      redirect_with_inertia_flash(:errors, Current.user.errors.full_messages, edit_user_path) :
      render(json: { errors: Current.user.errors.full_messages }, status: :unprocessable_entity)
  end

  def inertia_request?
    request.headers["X-Inertia"].present?
  end

  def user_params
    params.require(:user).permit(:first_name, :last_name, :timezone, :avatar, :theme, :chat_colour, :theme_hue, :default_account_key, preferences: [ :theme ], profile_attributes: [ :first_name, :last_name, :timezone, :avatar, :theme, :chat_colour, :theme_hue ])
  end

  def theme_changed?
    params[:user][:theme].present? ||
    params[:user][:preferences]&.key?(:theme) ||
    params[:user][:profile_attributes]&.key?(:theme)
  end

  def set_theme_cookie
    cookies[:theme] = {
      value: Current.user.theme,
      expires: 1.year.from_now,
      httponly: true,
      secure: Rails.env.production?
    }
  end

end

class UsersController < ApplicationController

  def edit
    render inertia: "user/edit", props: {
      timezones: timezone_options,
      colour_options: Profile::VALID_CHAT_COLOURS
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
    params_for_user, params_for_profile = separate_user_and_profile_params

    User.transaction do
      return false unless Current.user.update(params_for_user)

      if params_for_profile.present?
        unless Current.user.profile.update(params_for_profile)
          # Add profile errors to user errors
          Current.user.profile.errors.each do |error|
            Current.user.errors.add(error.attribute, error.message)
          end
          return false
        end
      end
    end

    audit_user_changes
    set_theme_cookie if theme_changed?
    respond_with_update_success
    true
  end

  def handle_update_failure
    respond_with_update_errors
  end

  def audit_user_changes
    audit_with_changes(determine_audit_action, Current.user)
  end

  def determine_audit_action
    changes = Current.user.saved_changes.except(:updated_at)
    profile_changes = Current.user.profile&.saved_changes || {}
    return :change_theme if profile_changes.key?("theme")
    return :update_timezone if profile_changes.key?("timezone")
    return :set_avatar if avatar_being_updated?
    :update_profile
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
    params.require(:user).permit(:first_name, :last_name, :timezone, :avatar, :theme, :chat_colour, :theme_hue, preferences: [ :theme ], profile_attributes: [ :first_name, :last_name, :timezone, :avatar, :theme, :chat_colour, :theme_hue ])
  end

  def separate_user_and_profile_params
    all_params = user_params.dup
    profile_attributes = [ :first_name, :last_name, :timezone, :avatar, :theme, :chat_colour, :theme_hue ]

    # Extract profile attributes directly sent
    profile_params = all_params.extract!(*profile_attributes)

    # Handle preferences format (legacy)
    if all_params[:preferences].present?
      preferences = all_params.delete(:preferences)
      profile_params[:theme] = preferences[:theme] if preferences[:theme].present?
    end

    # Also handle nested profile_attributes format
    if all_params[:profile_attributes].present?
      profile_params.merge!(all_params.delete(:profile_attributes))
    end

    [ all_params, profile_params ]
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

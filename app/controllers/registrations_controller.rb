class RegistrationsController < ApplicationController

  include AccountCapacity
  before_action :require_account_capacity, only: %i[ new create ]

  require_feature_enabled :signups, only: [ :new, :create ]
  allow_unauthenticated_access only: %i[ new create confirm_email set_password update_password check_email ]
  before_action :redirect_if_authenticated, only: [ :new ]
  before_action :load_pending_user, only: [ :set_password, :update_password ]

  def new
    render inertia: "registrations/new"
  end

  def create
    register_user || redirect_with_registration_errors
  end

  def check_email
    render inertia: "registrations/check_email"
  end

  def confirm_email
    confirm_account_and_redirect || redirect_with_invalid_token
  end

  def set_password
    return redirect_with_invalid_password_request if user_already_has_password?

    render inertia: "registrations/set_password", props: { email: @user.email_address, user: @user.as_json }
  end

  def update_password
    complete_registration || redirect_with_password_errors
  end

  private

  def register_user
    user = User.register!(normalized_email)
    membership = user.memberships.last

    return redirect_for_existing_user if membership.confirmed?

    redirect_with_confirmation_sent(user.was_new_record?)
    true
  rescue ActiveRecord::RecordInvalid => e
    @registration_errors = e.record.errors.to_hash(true)
    false
  end

  def redirect_for_existing_user
    redirect_to signup_path, inertia: {
      errors: { email_address: [ "This email is already registered. Please log in." ] }
    }
  end

  def redirect_with_confirmation_sent(was_new_user)
    notice = was_new_user ?
      "Please check your email to confirm your account." :
      "Confirmation email resent. Please check your inbox."
    redirect_to check_email_path, notice: notice
  end

  def redirect_with_registration_errors
    redirect_to signup_path, inertia: { errors: @registration_errors }
  end

  def confirm_account_and_redirect
    membership = Membership.confirm_by_token!(params[:token])
    user = membership.user

    user.password_digest? ? redirect_confirmed_user : redirect_for_password_setup(user)
    true
  rescue ActiveRecord::RecordNotFound, ActiveSupport::MessageVerifier::InvalidSignature
    false
  end

  def redirect_confirmed_user
    redirect_to login_path, notice: "Email confirmed! Please log in."
  end

  def redirect_for_password_setup(user)
    session[:pending_password_user_id] = user.id
    redirect_to set_password_path, notice: "Email confirmed! Please set your password."
  end

  def redirect_with_invalid_token
    redirect_to signup_path, alert: "Invalid or expired confirmation link. Please sign up again."
  end

  def user_already_has_password?
    @user&.password_digest?
  end

  def redirect_with_invalid_password_request
    redirect_to login_path, alert: "Invalid request. Please log in."
  end

  def complete_registration
    all_params = password_params.dup
    profile_data = all_params.extract!(:first_name, :last_name)

    User.transaction do
      return false unless @user.update(all_params)

      if profile_data.present?
        @user.profile.update!(profile_data)
      end
    end

    session.delete(:pending_password_user_id)
    start_new_session_for @user
    audit(:complete_registration, @user)
    redirect_to after_authentication_url, notice: "Account setup complete! Welcome!"
    true
  end

  def redirect_with_password_errors
    flash[:errors] = @user.errors.full_messages
    redirect_to set_password_path
  end

  def normalized_email
    params[:email_address]&.strip&.downcase
  end

  def redirect_if_authenticated
    redirect_to root_path, alert: "You are already signed in." if authenticated? && !Current.user.is_site_admin?
  end

  def load_pending_user
    @user = User.find_by(id: session[:pending_password_user_id])
    redirect_to login_path, alert: "Invalid request. Please log in." unless @user
  end

  def password_params
    params.permit(:password, :password_confirmation, :first_name, :last_name)
  end

end

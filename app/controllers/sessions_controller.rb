class SessionsController < ApplicationController

  allow_unauthenticated_access only: %i[ new create ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_session_url, alert: "Try again later." }

  def new
    authenticated? ? redirect_to_authenticated : render_login_page
  end

  def create
    return redirect_for_incomplete_user if incomplete_user?

    authenticate_and_login || redirect_with_authentication_error
  end

  def destroy
    audit(:logout)
    terminate_session
    redirect_to root_path, notice: "You have been signed out."
  end

  private

  def session_params
    params.permit(:email_address, :password)
  end

  def redirect_to_authenticated
    redirect_to root_path, notice: "You are already signed in."
  end

  def render_login_page
    render inertia: "sessions/new"
  end

  def find_user_by_email
    email = session_params[:email_address]&.strip&.downcase
    User.find_by(email_address: email)
  end

  def incomplete_user?
    @user = find_user_by_email
    @user && !@user.can_login?
  end

  def redirect_for_incomplete_user
    message = @user.confirmed? ? "Please complete your account setup first." : "Please confirm your email address first."
    redirect_to signup_path, alert: message
  end

  def authenticate_and_login
    return false unless user = User.authenticate_by(session_params)

    start_new_session_for user
    audit(:login, user)
    redirect_after_login
    true
  end

  # Native-app sign-in (/oauth/authorize) ends in a redirect to the app's
  # callback, which the login form's Inertia request can't follow: hand the
  # browser a full-page visit instead.
  def redirect_after_login
    url = after_authentication_url
    if request.inertia? && URI(url).path == oauth_authorization_path
      inertia_location url
    else
      redirect_to url, notice: "You have been signed in."
    end
  end

  def redirect_with_authentication_error
    redirect_to login_path, alert: "Invalid email or password.",
      inertia: { errors: { email_address: [ "Invalid email or password." ] } }
  end

end

module Authentication

  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :authenticated?
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private
    def authenticated?
      resume_session
    end

    def require_authentication
      resume_session || request_authentication
    end

    def resume_session
      Current.session ||= find_session_by_cookie
    end

    def authentication_cookie_name
      LocalInstance.current.cookie(:session_id)
    end

    def find_session_by_cookie
      Session.find_by(id: cookies.signed[authentication_cookie_name]) if cookies.signed[authentication_cookie_name]
    end

    def request_authentication
      session[:return_to_after_authenticating] = request.url
      redirect_to login_path
    end

    def after_authentication_url(landing_url: nil)
      session.delete(:return_to_after_authenticating) || landing_url || first_resident_url || root_url
    end

    # Someone whose only account is their own and who has no resident yet has
    # nothing to do on the home page: the next step is making a resident, so
    # sign-up and sign-in land them on that screen instead of the marketing page.
    def first_resident_url
      user = Current.session&.user
      return unless user

      accounts = user.confirmed_accounts.to_a
      return unless accounts.one?

      account = accounts.first
      return unless account.personal_account_for?(user)
      return if account.agents.exists?

      new_account_agent_url(account)
    end

    def start_new_session_for(user)
      user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |session|
        Current.session = session
        cookies.signed.permanent[authentication_cookie_name] = { value: session.id, httponly: true, same_site: :lax }
      end
    end

    def terminate_session
      Current.session.destroy
      cookies.delete(authentication_cookie_name)
    end

end

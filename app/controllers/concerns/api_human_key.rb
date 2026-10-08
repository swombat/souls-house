# Guards for /api/v1 endpoints that mirror a person's own browser controls.
#
# The browser finds the account among the signed-in person's confirmed
# accounts (AccountScoping#find_current_user_account!), so a key whose person
# is no longer a confirmed member reaches nothing: 404, not 403, so the
# account's existence isn't confirmed. Resident keys are refused with 403.
module ApiHumanKey

  extend ActiveSupport::Concern

  class_methods do
    def require_human_member(**options)
      before_action :require_human_key!, **options
      before_action :require_account_member!, **options
    end

    # The web's `require_feature_enabled :agents`, answered in JSON.
    def require_api_feature_enabled(feature, **options)
      before_action(**options) do
        unless Setting.instance.public_send(:"allow_#{feature}?")
          render json: { error: "This feature is currently disabled" }, status: :forbidden
        end
      end
    end
  end

  private

  def require_human_key!
    return unless current_api_agent

    render json: { error: "This endpoint needs a person's API key, not a resident's" }, status: :forbidden
  end

  def require_account_member!
    return if current_api_account.accessible_by?(current_api_user)

    render json: { error: "Not found" }, status: :not_found
  end

end

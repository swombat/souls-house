# Doorkeeper's token endpoint plus refresh-token reuse detection and device
# logout (issue #94, PR A). Doorkeeper rejects an already-revoked refresh token
# in validation, before its own InvalidGrantReuse check, so detection lives
# here, ahead of the request, under the AppSession row lock that also
# serialises token creation for the chain. The lookup hashes the presented
# value (hash_token_secrets), so it finds revoked rows too.
class Oauth::TokensController < Doorkeeper::TokensController

  rate_limit to: 30, within: 1.minute, only: :create,
             with: -> { render json: { error: "rate_limited" }, status: :too_many_requests }

  # Exact callback at code exchange too: Doorkeeper's URIChecker would accept
  # the grant's callback with a query string appended.
  before_action :require_exact_redirect_uri, only: :create

  def create
    presented = refresh_grant? && Doorkeeper::AccessToken.by_refresh_token(params[:refresh_token].to_s)
    return super unless presented

    AppSession.transaction do
      app_session = AppSession.lock.find(presented.app_session_id)
      presented.reload

      next render_signed_out if app_session.revoked?

      # Answered here rather than by super, so nothing Doorkeeper raises can
      # roll the family revocation back.
      if presented.revoked?
        app_session.revoke!(:reuse_detected)
        next render_signed_out
      end

      super

      # Still under the lock, so the newest token in the chain is the one just minted.
      app_session.supersede_siblings_of!(app_session.access_tokens.order(:id).last, presented: presented) if response.successful?
    end
  end

  # Revoking any token of a device signs the device out: the whole chain goes,
  # so a stale refresh token replayed later is an invalid grant, never "theft".
  def revoke
    token.app_session&.revoke!(:logout) if token.present? && authorized?
    super
  end

  private

  def require_exact_redirect_uri
    return unless params[:grant_type] == Doorkeeper::OAuth::AUTHORIZATION_CODE

    grant = Doorkeeper::AccessGrant.by_token(params[:code].to_s)
    return if grant.nil? || grant.redirect_uri == params[:redirect_uri].to_s

    render json: { error: "invalid_grant", error_description: "The redirect URI does not match the one used for the grant." },
           status: :bad_request
  end

  def render_signed_out
    render json: { error: "invalid_grant", error_description: "This device has been signed out." }, status: :bad_request
  end

  def refresh_grant?
    params[:grant_type] == Doorkeeper::OAuth::REFRESH_TOKEN && params[:refresh_token].present?
  end

end

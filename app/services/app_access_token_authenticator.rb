# Validates a native-app OAuth bearer (issue #94) and returns its live
# AppSession, or nil. Shared by /api/app/v1 and /api/v1 so both accept the same
# token under the same rules.
#
# Not doorkeeper_token: Doorkeeper's authenticate retires the parent refresh
# token for any row it finds, even a revoked or expired one, so a rejected
# superseded bearer would end the parent's lost-response retry grace. Validate
# first; only a usable bearer retires its parent, and under the family lock the
# token endpoint also holds.
class AppAccessTokenAuthenticator

  def self.authenticate(request)
    presented = Doorkeeper::OAuth::Token.from_request(request, *Doorkeeper.config.access_token_methods)
    return if presented.blank?

    token = Doorkeeper::AccessToken.by_token(presented)
    return unless usable?(token)

    if token.previous_refresh_token.present?
      AppSession.transaction do
        AppSession.lock.find(token.app_session_id)
        token.reload
        token.revoke_previous_refresh_token! if usable?(token)
      end
      return unless usable?(token)
    end

    token.app_session.tap(&:touch_last_used!)
  end

  def self.usable?(token)
    token&.accessible? && token.acceptable?(:chat) && token.app_session.present? && !token.app_session.revoked?
  end

end

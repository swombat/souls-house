# Doorkeeper's authorize endpoint with exact callback matching (issue #94,
# PR A). Doorkeeper's URIChecker drops the request's query string when the
# registered callback has none, so ".../callback?x=1" would pass; a native
# client's callback must be one of the registered URIs, byte for byte. This
# runs before sign-in, so a bad callback never detours through the login page.
class Oauth::AuthorizationsController < Doorkeeper::AuthorizationsController

  DEVICE_LABEL_LIMIT = 100

  prepend_before_action :require_exact_redirect_uri
  before_action :clamp_device_label

  private

  def require_exact_redirect_uri
    client = Doorkeeper::Application.by_uid(params[:client_id].to_s)
    return if client && client.redirect_uri.split.include?(params[:redirect_uri].to_s)

    render plain: "This app's sign-in link is not valid.", status: :bad_request
  end

  # The label is display-only, copied grant → token → AppSession; keep it short.
  def clamp_device_label
    params[:device_label] = params[:device_label].to_s.first(DEVICE_LABEL_LIMIT) if params.key?(:device_label)
  end

end

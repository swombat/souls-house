# For endpoints where a key acts only in its own (home) account: Field files
# and recordings, whiteboards and their versions. A key that names any other
# account_id gets 404. It never quietly falls back to its own account, which
# would make a request aimed at B read or change A.
#
# A resident key that is a guest elsewhere is refused too: these endpoints
# have always served only its home account, and this doesn't widen that.
# An OAuth token is untouched, because ApiAuthentication#resolve_app_account
# already resolves account_id (or refuses it) for app sign-ins.
module ApiHomeAccountOnly

  extend ActiveSupport::Concern

  included do
    before_action :refuse_foreign_account_id!
  end

  private

  def refuse_foreign_account_id!
    return if app_token_request?
    return if params[:account_id].blank?
    return if params[:account_id].is_a?(String) && Account.decode_id(params[:account_id]) == current_api_account.id

    raise ActiveRecord::RecordNotFound
  rescue Hashids::InputError
    raise ActiveRecord::RecordNotFound
  end

end

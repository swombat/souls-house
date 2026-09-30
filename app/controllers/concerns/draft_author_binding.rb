# A tab may outlive logout/login in another tab. Never upload the previous
# user's editor through the replacement user's session cookie.
module DraftAuthorBinding

  extend ActiveSupport::Concern

  private

  def require_matching_draft_author
    expected = request.headers["X-Draft-User"]
    head :forbidden if expected.present? && expected != Current.user.to_param
  end

end

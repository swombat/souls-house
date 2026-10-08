# Where a person's credential may find the thing it acts on, for the Field,
# whiteboard and device-stream endpoints. Authority itself is ApiHumanActor's
# (require_human_actor!, human_account!); this only decides which accounts to
# look in, like ApiAuthentication#human_chats does for rooms:
#
# - an account key looks in its own account, and naming any other account_id
#   is 404 (requested_account), never a quiet fallback to the key's account;
# - an OAuth token with account_id looks only in that account;
# - an OAuth token without one looks in every enabled account the person
#   currently belongs to, so a resource in their second account is reachable
#   by its id alone.
#
# The record found is then checked with human_account!(record.account), so
# every action is authorised against the resource's own account.
module ApiHumanReach

  extend ActiveSupport::Concern

  class_methods do
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

  def human_reachable_accounts
    return current_api_user.confirmed_accounts if app_token_request? && params[:account_id].blank?

    Account.where(id: requested_account.id)
  end

  # One record by its public id, in an account this request may reach, and
  # only if the person may act in that record's account now (else 404).
  def find_human_record!(scope, id)
    record = scope.where(account_id: human_reachable_accounts.select(:id)).find_by!(id: scope.klass.decode_id(id))
    human_account!(record.account)
    record
  rescue Hashids::InputError
    raise ActiveRecord::RecordNotFound
  end

  # The account a collection or create acts in (account_id, the key's
  # account, or the person's default), if the person may act in it now. A key
  # naming an account_id other than its own gets 404 (requested_account).
  def human_request_account!
    @human_request_account ||= human_account!(requested_account)
  end

end

# Statuses for the commit references in a chat the reader can see: the
# house's own repository for site admins, and the account's repositories
# that have commit badges switched on (CommitBadges).
class Accounts::CommitStatusesController < ApplicationController

  # GET /accounts/:account_id/commit_statuses?refs=51625a7,owner/name@783ab2e
  def index
    render json: CommitBadges.new(account: current_account, user: Current.user).lookup(params[:refs].to_s.split(","))
  end

end

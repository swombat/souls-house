# Cancel a repository watch from the GitHub card. Any member of the account
# may cancel one, as through DELETE /api/v1/watches/:id.
class Accounts::RepositoryWatchesController < ApplicationController

  # DELETE /accounts/:account_id/watches/:id
  def destroy
    watch = RepositoryWatch.where(account_id: current_account.id).find(params[:id])
    if watch.cancel!(reason: "cancelled by #{Current.user.display_name}")
      audit("repository_watch.cancel", watch, repository: watch.watched_repository.full_name)
      redirect_back fallback_location: account_integrations_path(current_account), notice: "Watch cancelled"
    else
      redirect_back fallback_location: account_integrations_path(current_account), alert: "That watch is no longer armed"
    end
  end

end

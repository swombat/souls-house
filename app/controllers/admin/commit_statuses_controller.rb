class Admin::CommitStatusesController < ApplicationController

  skip_before_action :set_current_account
  before_action :require_site_admin

  def index
    shas = params[:shas].to_s.split(",")
    summary = DeployInfo.summary
    render json: {
      statuses: CommitStatus.lookup(shas, summary:),
      revision: CommitStatus.revision(summary)
    }
  end

  private

  def require_site_admin
    head :not_found unless Current.user&.is_site_admin?
  end

end

class Admin::CommitStatusesController < ApplicationController

  skip_before_action :set_current_account
  before_action :require_site_admin

  def index
    shas = params[:shas].to_s.split(",")
    render json: { statuses: CommitStatus.lookup(shas) }
  end

  private

  def require_site_admin
    head :not_found unless Current.user&.is_site_admin?
  end

end

class Admin::DeployInfosController < ApplicationController

  skip_before_action :set_current_account
  before_action :require_site_admin

  def show
    render json: DeployInfo.summary.merge(workflows: HouseDeploy.workflows, alarm: DeployAlarm.payload)
  end

  private

  def require_site_admin
    head :not_found unless Current.user&.is_site_admin?
  end

end

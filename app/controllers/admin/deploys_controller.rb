class Admin::DeploysController < ApplicationController

  skip_before_action :set_current_account
  before_action :require_site_admin

  def index
    render inertia: "admin/deploys", props: {
      workflows: HouseDeploy.workflows,
      repo: HouseDeploy.repo,
      deploy_status: -> { HouseDeploy.status }
    }
  end

  def create
    key = params[:workflow].to_s
    config = HouseDeploy.dispatch!(key)
    audit(:admin_deploy_dispatched, nil, workflow: key, ref: HouseDeploy::REF)
    redirect_to admin_deploys_path, notice: "#{config[:name]} requested. GitHub usually shows the run within a few seconds."
  rescue HouseDeploy::Error => e
    audit(:admin_deploy_failed, nil, workflow: key, error: e.message)
    redirect_to admin_deploys_path, alert: e.message
  end

  private

  def require_site_admin
    redirect_to root_path unless Current.user&.is_site_admin?
  end

end

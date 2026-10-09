class Admin::DashboardsController < ApplicationController

  CACHE_KEY = "admin/site_dashboard/v1".freeze
  CACHE_FOR = 5.minutes

  skip_before_action :set_current_account
  before_action :require_site_admin

  def show
    Rails.cache.delete(CACHE_KEY) if params[:refresh].present?
    dashboard = Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_FOR) { SiteDashboard.new.call }
    render inertia: "admin/dashboard", props: { dashboard: dashboard, cached_for_seconds: CACHE_FOR.to_i }
  end

  private

  def require_site_admin
    redirect_to root_path unless Current.user&.is_site_admin?
  end

end

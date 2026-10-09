class Admin::DashboardsController < ApplicationController

  CACHE_FOR = 5.minutes

  skip_before_action :set_current_account
  before_action :require_site_admin

  def show
    SiteDashboard.expire_cache! if params[:refresh].present?
    # race_condition_ttl lets one request recompute an expired entry while
    # others keep serving the old one for a few seconds.
    dashboard = Rails.cache.fetch(SiteDashboard::CACHE_KEY, expires_in: CACHE_FOR, race_condition_ttl: 30.seconds) do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      SiteDashboard.new.call.tap do |result|
        result[:computed_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        Rails.logger.info("SiteDashboard computed in #{result[:computed_ms]}ms")
      end
    end
    render inertia: "admin/dashboard", props: { dashboard: dashboard, cached_for_seconds: CACHE_FOR.to_i }
  end

  private

  def require_site_admin
    redirect_to root_path unless Current.user&.is_site_admin?
  end

end

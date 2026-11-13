# When Hetzner can sell the small shared server types (CX and CAX), from the
# five-minute checks: the last 100 checks, and a week of the four pairs.
class Admin::HetznerAvailabilitiesController < ApplicationController

  skip_before_action :set_current_account
  before_action :require_site_admin

  WINDOW = 7.days

  def show
    now = Time.current
    render inertia: "admin/hetzner-availability", props: {
      now: now.iso8601,
      types: HetznerAvailabilitySample::TYPES,
      checks: HetznerAvailabilitySample.recent_checks(100).map { |check| check.merge(at: check[:at].iso8601) },
      series: HetznerAvailabilitySample.pair_series(now - WINDOW).map do |line|
        line.merge(points: line[:points].map { |time, value| [ time.iso8601, value ] })
      end
    }
  end

  private

  def require_site_admin
    redirect_to root_path unless Current.user&.is_site_admin?
  end

end

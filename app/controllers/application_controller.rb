class ApplicationController < ActionController::Base

  include Pagy::Method

  include Authentication
  include AccountScoping
  include FeatureToggleable
  allow_browser versions: :modern

  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found

  inertia_share flash: -> { flash.to_hash }
  inertia_share do
    if authenticated?
      {
        user: Current.user.as_json,
        account: current_account&.as_json,
        accounts: Current.user.confirmed_accounts.map(&:as_json),
        account_has_whiteboards: current_account&.whiteboards&.active&.exists? || false,
        theme_preference: Current.user&.theme || cookies[:theme],
        site_settings: shared_site_settings,
        is_account_admin: current_account&.manageable_by?(Current.user) || false,
        token_thresholds: { amber: 100_000, red: 150_000, critical: 200_000 }
      }
    else
      {
        theme_preference: cookies[:theme],
        site_settings: shared_site_settings
      }
    end
  end

  wrap_parameters false # Disable default wrapping of parameters in JSON requests (Helpful with Inertia js)

  private

  def record_not_found
    if request.headers["X-Inertia"]
      # For Inertia requests, render a proper Inertia error response
      head :not_found
    else
      respond_to do |format|
        format.html { render file: "#{Rails.root}/public/404.html", status: :not_found, layout: false }
        format.json { render json: { error: "Record not found" }, status: :not_found }
        format.any { head :not_found }
      end
    end
  end

  def redirect_with_inertia_flash(type, message, path = nil)
    flash[type] = message
    redirect_to path || request.referer || root_path
  end

  # Centralized audit logging methods
  # Keep all AuditLog.create calls here so if audit logging principles change,
  # we only need to update in one place rather than hunting throughout the codebase

  def audit(action, auditable = nil, **data)
    return unless Current.user

    AuditLog.create!(
      user: Current.user,
      account: Current.account,
      action: action,
      auditable: auditable,
      data: data.presence,
      ip_address: request.remote_ip,
      user_agent: request.user_agent
    )
  end

  def audit_with_changes(action, record, **extra_data)
    return unless Current.user

    changes = record.saved_changes.except(:updated_at)
    data = extra_data.merge(changes)
    data = ActiveSupport::ParameterFilter
      .new(Rails.application.config.filter_parameters)
      .filter(data)

    audit(action, record, **data)
  end

  # Use this method only when logging actions for a user outside of an authenticated session
  # (e.g., password reset requests where the user isn't logged in)
  def audit_as(user, action, auditable = nil, **data)
    AuditLog.create!(
      user: user,
      account: user.personal_account,
      action: action,
      auditable: auditable,
      data: data.presence,
      ip_address: request.remote_ip,
      user_agent: request.user_agent
    )
  end

  def shared_site_settings
    settings = Setting.instance
    {
      site_name: settings.site_name,
      logo_url: settings.logo.attached? ? url_for(settings.logo) : nil,
      allow_signups: settings.allow_signups,
      allow_chats: settings.allow_chats,
      allow_agents: settings.allow_agents
    }
  end

  def pagy_to_hash(pagy)
    return {} unless pagy

    {
      count: pagy.count,
      page: pagy.page,
      pages: pagy.pages,
      last: pagy.last,
      from: pagy.from,
      to: pagy.to,
      prev: pagy.previous,
      next: pagy.next,
      series: pagy.send(:series).map(&:to_s),
      per_page: pagy.limit.to_s
    }
  end

end

class Admin::AgentRuntimeSessionsController < ApplicationController

  MAX_WINDOW = 31.days

  skip_before_action :set_current_account
  before_action :require_site_admin

  def index
    report = ResidentSessionActivityReport.new(
      window: params[:window],
      channel: params[:channel],
      time_zone: Current.user.timezone.presence || "UTC"
    ).call

    render inertia: "admin/runtime-sessions", props: {
      report: report
    }
  end

  def show
    agent = Agent.includes(:account).find(params[:agent_id])
    to = parse_time(params[:to]) || Time.current.utc
    from = parse_time(params[:from]) || (to - 24.hours)
    from = to - 24.hours if from > to
    from = [ from, to - MAX_WINDOW ].max

    report = AgentRuntimeUsageReport.new(
      agent: agent,
      from: from,
      to: to,
      filters: report_filter_params
    ).call

    render inertia: "admin/agent-runtime-sessions", props: {
      agent: {
        id: agent.to_param,
        name: agent.name,
        runtime: agent.runtime,
        account_id: agent.account.to_param,
        account_name: agent.account.name
      },
      report: report,
      filters: report.fetch(:window).merge(report.fetch(:filters)),
      selected_session_id: selected_session_id(report)
    }
  end

  private

  def parse_time(value)
    return unless value.is_a?(String) && value.present?

    Time.iso8601(value).utc
  rescue ArgumentError, TypeError
    nil
  end

  def report_filter_params
    params.permit(
      :trigger_kind,
      :provider,
      :model,
      :session_outcome,
      :session_roll_reason
    )
  end

  def selected_session_id(report)
    requested = params[:session_id].presence
    return if requested.blank?

    requested if report.fetch(:sessions).any? { |session| session[:session_id] == requested }
  end

  def require_site_admin
    redirect_to root_path unless Current.user&.is_site_admin?
  end

  def current_account
    nil
  end

end

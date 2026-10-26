class Agents::HostingDiagnosticsController < ApplicationController

  include AgentScoped

  # Container internals and a reader for the resident's own files (journals,
  # soul, memory): operator material, not something every owner browses.
  before_action :require_site_admin!

  def show
    reconcile_orientation_from_journals!

    render json: {
      sandbox_status: Agents::Sandbox.new(@agent).status,
      filesystem_dump: Agents::FilesystemDump.new(@agent).as_json,
      container_filesystem_dump: Agents::FilesystemDump.new(@agent, target: :container_home).as_json
    }
  end

  def file_preview
    target = params[:target].presence || :identity
    render json: Agents::FilesystemDump.new(@agent, target: target).file_preview_json(params[:path])
  end


  private

  def require_site_admin!
    head :forbidden unless Current.user&.is_site_admin?
  end

  def reconcile_orientation_from_journals!
    return unless @agent.external? && @agent.oriented_at.blank?

    @agent.update!(oriented_at: Time.current) if Agents::DailyJournalStatus.new(@agent).entries?
  rescue StandardError => e
    Rails.logger.debug { "[HostingDiagnostics] orientation journal check skipped for agent #{@agent.id}: #{e.class}: #{e.message}" }
  end

end

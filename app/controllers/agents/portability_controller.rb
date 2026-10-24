class Agents::PortabilityController < ApplicationController

  require_feature_enabled :agents
  before_action :require_account_owner!
  before_action :private_response

  rescue_from Agents::Portability::Error do |error|
    render json: { error: error.message.presence || "Invalid resident archive" }, status: :unprocessable_entity
  end

  rescue_from Agents::Resources::OwnershipError, ActiveRecord::LockWaitTimeout do
    render json: { error: "Resident archive unavailable or invalid. Check v1 limits, stopped state and supported profile." }, status: :unprocessable_entity
  end

  def new
    render inertia: "agents/import", props: {
      account: current_account.as_json,
      import_url: import_archive_account_agents_path(current_account),
      preview_url: import_preview_account_agents_path(current_account)
    }
  end

  def export
    agent = current_account.agents.find(params[:id])
    download = nil
    Agents::Portability::Export.call(agent, exporter: Current.user) do |path|
      download = Tempfile.new([ "resident-download-", ".tar.gz" ])
      download.chmod(0600)
      File.open(path, "rb") { |file| IO.copy_stream(file, download) }
      download.rewind
      response.headers["Content-Type"] = "application/gzip"
      response.headers["Content-Length"] = download.size.to_s
      response.headers["Content-Disposition"] = ActionDispatch::Http::ContentDisposition.format(disposition: "attachment", filename: "resident-#{agent.to_param}.tar.gz")
      self.response_body = Download.new(download)
    end
  rescue StandardError
    download&.close!
    raise
  end

  def stop
    agent = current_account.agents.find(params[:id])
    raise Agents::Portability::Error, "V1 stop/export supports native hosted residents only" unless agent.externally_hosted? && !agent.imported_home?
    raise Agents::Portability::Error, "Confirm that idle background processes may stop" unless params[:confirmed].to_s == "true"
    agent.with_lock do
      agent.update!(active: false, paused: true)
    end
    # Admission remains disabled even on busy failure; do not roll this back.
    agent.with_lock do
      raise Agents::Portability::Error, "Resident remains paused/inactive: wait for pending or uncertain turns to finish" if ResidentTurn.pending.where(agent: agent).exists? || agent.agent_runtime_interactions.where(finished_at: nil).exists?
      sandbox = Agents::Sandbox.new(agent)
      Agents::Portability::Transport.new(agent).idle!
      sandbox.stop!
      Agents::Portability::Transport.new(agent).stopped!
    end
    redirect_to edit_account_agent_path(current_account, agent, tab: "portability"), status: :see_other
  end

  def activate
    agent = current_account.agents.find(params[:id])
    raise Agents::Portability::Error, "Confirm service and hook trust review before activation" unless params[:confirmed].to_s == "true"
    # A copy staged for its own server is never started here: Activate admits
    # it, and ProvisionVmAgentJob brings it up there
    # (docs/2026-10-10-vm-imports.md). The confirmation above is its trust
    # boundary, recorded with who asked.
    return activate_on_vm!(agent) if agent.placement&.kind == "archive_import"
    raise Agents::Portability::Error, "Only stopped inactive native residents can activate here" unless !agent.imported_home? && agent.externally_hosted? && !agent.active? && agent.paused?
    activation_error = nil
    agent.with_lock do
      raise Agents::Portability::Error, "Only inactive paused native residents can activate here" unless !agent.imported_home? && agent.externally_hosted? && !agent.active? && agent.paused?
      # Recheck under the same start/export gate. Rejections never stop anything.
      raise Agents::Portability::Error, "Resident has pending or uncertain execution" if ResidentTurn.pending.where(agent: agent).exists? || agent.agent_runtime_interactions.where(finished_at: nil).exists?
      transport = Agents::Portability::Transport.new(agent)
      transport.stopped!
      previous_active = agent.active?
      agent.update_columns(active: true)
      begin
        Agents::Sandbox.new(agent).spawn!
        agent.update_columns(paused: false, scheduled_wakes_enabled: agent.portability_custody.present? ? false : agent.scheduled_wakes_enabled?)
      rescue StandardError
        agent.update_columns(active: false, paused: true, runtime: "offline")
        begin
          Agents::Sandbox.new(agent).stop!
          transport.stopped!
          activation_error = "Activation failed; resident remains paused/inactive. Check target runtime setup"
        rescue StandardError
          agent.update_columns(health_state: "unknown", sandbox_last_error: "Activation failed; runtime exit unverified", sandbox_last_error_at: Time.current)
          activation_error = "Activation failed; resident inactive/paused but runtime exit is UNKNOWN. Operator verification required"
        end
      end
      # The failure paths intentionally use direct columns, not orientation callbacks.
      agent.refresh_provider_presentation if activation_error
      HomeResidentRoster.refresh!([ agent.account_id ]) if agent.active? != previous_active
    end
    raise Agents::Portability::Error, activation_error if activation_error
    redirect_to edit_account_agent_path(current_account, agent, tab: "portability"), status: :see_other
  end

  def preview
    Agents::Portability::Archive.with_upload(params[:archive]) do |archive|
      render json: { preview: archive.preview(current_account) }
    end
  end

  def create
    raise Agents::Portability::Error unless params[:confirmed].to_s == "true"
    Agents::Portability::Archive.with_upload(params[:archive]) do |archive|
      agent = Agents::Portability::Import.call(archive, account: current_account, user: Current.user, name: params[:name])
      notice = if agent.placement&.staged?
        "Separate copy staged inactive and paused for its own server. Nothing is ordered until you activate it. Reconnect and review setup before starting."
      else
        "Separate copy restored inactive and paused. Reconnect and review setup before starting."
      end
      redirect_to edit_account_agent_path(current_account, agent, tab: "portability"), status: :see_other, notice: notice
    end
  end

  class Download

    def initialize(file) = @file = file

    def each
      while (chunk = @file.read(64.kilobytes))
        yield chunk
      end
    ensure
      close
    end

    def close = @file.close!

  end

  private

  def activate_on_vm!(agent)
    placement = agent.placement
    raise Agents::Portability::Error, "This resident is already running on its own server" if placement.state == "ready"
    if %w[failed retired].include?(placement.state)
      raise Agents::Portability::Error, "Its last start on its own server failed, and trying again isn't available yet. " \
                                        "It stays imported, inactive and paused."
    end
    raise Agents::Portability::Error, "Only inactive paused residents can activate here" if agent.active? || !agent.paused?

    begin
      Agents::VmBirthPolicy.current.admit_import!(placement:, requested_by: Current.user)
    rescue Agents::VmBirthPolicy::Refused => error
      raise Agents::Portability::Error, error.message
    end
    AuditLog.create!(user: Current.user, account: agent.account, action: "vm_import_activation_admitted", auditable: agent,
      data: { "placement_id" => placement.id, "confirmed_trust_review" => true })
    agent.update_columns(runtime: "provisioning", health_state: "unknown", sandbox_last_error: nil, sandbox_last_error_at: nil)
    ProvisionVmAgentJob.perform_later(agent.id)
    redirect_to edit_account_agent_path(current_account, agent, tab: "portability"), status: :see_other,
      notice: "Ordering its own server. It starts once its home is seeded and its first backup is verified."
  end

  def private_response
    response.headers["Cache-Control"] = "private, no-store"
    request.set_header("action_dispatch.parameter_filter", [ /./ ])
  end

  # Runs before request parameter instrumentation; no archived content in logs.
  def process_action(*)
    request.set_header("action_dispatch.parameter_filter", [ /./ ])
    super
  end

end

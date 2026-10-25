class GithubResidentImportJob < ApplicationJob

  queue_as :default

  def perform(id)
    request = GithubResidentImport.find(id)
    # With new residents on their own VM, a new import is admitted to one at
    # import (docs/2026-10-10-vm-imports.md, points 2 and 4), or fails with the
    # reason it can't be (cap, procurement, backups). Nothing is made here.
    # An account that pays per resident can't import one unpaid, even if the
    # request was made before the account started paying.
    if request.agent.nil? && (refusal = new_resident_refusal(request))
      request.with_lock do
        request.update!(status: "failed", last_error: refusal) if request.status == "approved"
      end
      return
    end
    request.with_lock do
      return unless request.status == "approved"
      request.require_approval!
      request.update!(status: "provisioning", last_error: nil)
    end
    # Already placed on its own VM: retried there, whatever the switch says
    # now, and never on the house.
    return continue_on_vm!(request) if on_vm?(request.agent)

    source = Agents::GithubImportSource.new(request.service_connection, sync_strategy: request.sync_strategy)
    source.with_checkout(branch: request.branch, commit_sha: request.approved_commit_sha) do |root, manifest, sha, branch|
      raise Agents::GithubImportSource::Error, "Reviewed home identity changed" unless
        manifest["identity_id"] == request.portable_home_id && sha == request.commit_sha && branch == request.branch
      agent = request.agent
      unless agent
        # Checked again here, after the checkout: the switch may have gone on
        # while the repository was being fetched, and this is the point where
        # a home would be made on the house.
        if (refusal = new_resident_refusal(request.reload))
          request.update!(status: "failed", last_error: refusal)
          return
        end
        return admit_on_vm!(request, root) if Agents::VmBirthPolicy.current.enabled?

        owner, repo = request.repository.split("/", 2)
        agent = request.build_agent(account: request.account, name: request.name, model_id: request.model_id,
          home_profile: "portable_v1", portable_home_id: request.portable_home_id,
          runtime: "provisioning", active: false, paused: true, scheduled_wakes_enabled: false,
          github_repo_owner: owner, github_repo_name: repo, github_repo_url: "https://github.com/#{request.repository}")
        Agents::HostedProvisioning.new(agent: agent, user: request.requested_by).prepare!(started_at: Time.current)
      end
      # The house-owned runtime follows deployments, not repository approval.
      # approved_image records provenance; it is not an execution pin.
      agent.update!(container_image: Agents::Config.default_image)
      request.reload.require_approval!
      volume = Agents::Volume.new(agent)
      # A retry never replaces a populated home. Interrupted seeding requires
      # operator investigation; do not infer completeness from non-emptiness.
      volume.seed_from_directory!(root) unless agent.identity_seeded_at
      agent.update!(identity_seeded_at: Time.current) unless agent.identity_seeded_at
      agent.agent_service_accesses.find_or_create_by!(service_connection: request.service_connection) do |access|
        access.enabled = true
        access.follows_default = false
      end
      sandbox = Agents::Sandbox.new(agent)
      unless sandbox.imported_runtime_trusted?
        agent.update!(active: false, paused: true, runtime: "offline")
        request.update!(status: "needs_runtime_trust", last_error: nil)
        return
      end
      agent.update!(active: true)
      if agent.runtime_ready_at
        raise Agents::Sandbox::SandboxError, "Wait for current execution to finish before changing credentials" if sandbox.active_turn?
        sandbox.recreate!
      else
        sandbox.spawn!
      end
      agent.update!(paused: false, runtime_ready_at: Time.current)
      request.update!(status: "ready")
    end
  rescue StandardError => error
    # Never persist upstream stderr, tokens or arbitrary exception text.
    if request
      request.agent&.update!(active: false, paused: true)
      request.update!(status: "failed", last_error: "Import or runtime setup failed. The existing home was preserved; review setup and approval before retrying.")
    end
    Rails.logger.error("GitHub resident import #{id} failed (#{error.class})")
    raise
  end

  private

  # Why a request with no resident yet can't make one now. A retry for a
  # resident already created is never refused here.
  def new_resident_refusal(request)
    Billing::BirthGate.refusal(request.account) || Agents::VmBirthPolicy.current.refusal(kind: :import)
  end

  def on_vm?(agent) = agent&.placement&.kind == "github_import"

  # A new import on its own VM. The reviewed checkout is packed now, outside
  # the admission lock; the resident, its placement and its staged home are
  # committed together under it. The server is bought, seeded, trust-checked
  # and started by ProvisionVmAgentJob. Nothing touches a house volume or
  # sandbox.
  def admit_on_vm!(request, root)
    begin
      packed = Agents::GithubImportStage.pack(root)
    rescue Agents::GithubImportStage::Error => error
      request.update!(status: "failed", last_error: error.message)
      return
    end
    owner, repo = request.repository.split("/", 2)
    # Built by id, not through request.build_agent: the request must never
    # hold an unsaved resident it could autosave outside admission (a
    # refusal's status write, the failure rescue below), which a later
    # approval would then find already made and take to the house (Mira's
    # review of #531). Only admit! saves it.
    agent = request.account.agents.new(github_resident_import_id: request.id, name: request.name, model_id: request.model_id,
      home_profile: "portable_v1", portable_home_id: request.portable_home_id,
      runtime: "provisioning", active: false, paused: true, scheduled_wakes_enabled: false,
      github_repo_owner: owner, github_repo_name: repo, github_repo_url: "https://github.com/#{request.repository}")
    begin
      Agents::VmBirthPolicy.current.admit!(agent:, requested_by: request.approved_by, kind: "github_import") do
        Agents::GithubImportStage.persist!(agent, packed)
      end
    rescue Agents::VmBirthPolicy::Refused => refused
      request.reload.update!(status: "failed", last_error: refused.message)
      return
    end
    request.reload
    Agents::HostedProvisioning.new(agent:, user: request.requested_by).prepare!(started_at: Time.current)
    agent.agent_service_accesses.find_or_create_by!(service_connection: request.service_connection) do |access|
      access.enabled = true
      access.follows_default = false
    end
    ProvisionVmAgentJob.perform_later(agent.id)
  end

  # An import already on its own VM, approved again or retried after runtime
  # trust was granted. A live server gets a fresh trust check (the operator
  # grants trust on Chaos's own screen there); a released one is admitted
  # again at its next generation, from the same staged home, under the same
  # checks as the first time. The staged home is never replaced: as on the
  # house, a retry never reseeds a home.
  def continue_on_vm!(request)
    agent = request.agent
    placement = agent.placement
    case placement.state
    when "pending", "ready"
      if agent.runtime_ready_at.present?
        # Ready and approved again: as on the house, trust is checked again
        # before the runtime is refreshed with the newly approved values.
        # ProvisionVmAgentJob carries it on; it never fails or cleans up a
        # ready resident's server.
        begin
          agent.update!(container_image: Agents::Config.default_image)
          Agents::RemoteRuntime.check_runtime_trust!(agent)
        rescue Agents::RemoteRuntime::Unavailable => e
          request.update!(status: "failed", last_error: "Its server could not be asked to check runtime trust: #{e.message}".first(1000))
          return
        end
      else
        recheck_trust!(agent, placement)
      end
    else
      begin
        Agents::VmBirthPolicy.current.admit_import!(placement:, requested_by: request.approved_by)
      rescue Agents::VmBirthPolicy::Refused => refused
        request.update!(status: "failed", last_error: refused.message)
        return
      end
      agent.update_columns(runtime: "provisioning", health_state: "unknown", sandbox_last_error: nil, sandbox_last_error_at: nil)
    end
    ProvisionVmAgentJob.perform_later(agent.id)
  end

  # Only a finished check that did not say trusted is asked again; one in
  # flight is left to answer, and a server not yet enrolled gets its first
  # check from ProvisionVmAgentJob.
  def recheck_trust!(agent, placement)
    last = RunnerCommand.where(agent_placement_id: placement.id, kind: "check_runtime_trust",
      generation: placement.generation).order(:id).last
    return if last.nil? || %i[pending trusted].include?(Agents::RemoteRuntime.runtime_trust_outcome(last))

    Agents::RemoteRuntime.check_runtime_trust!(agent)
  rescue Agents::RemoteRuntime::Unavailable => e
    Rails.logger.warn("[github_import] agent=#{agent.id} trust re-check not sent now: #{e.message}")
  end

end

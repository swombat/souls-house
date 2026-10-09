class GithubResidentImportJob < ApplicationJob

  queue_as :default

  def perform(id)
    request = GithubResidentImport.find(id)
    # An import approved before new residents went on their own VM would
    # otherwise make its home here. It fails with the reason instead.
    if request.agent.nil? && (refusal = Agents::VmBirthPolicy.current.refusal(kind: :import))
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
    source = Agents::GithubImportSource.new(request.service_connection, sync_strategy: request.sync_strategy)
    source.with_checkout(branch: request.branch, commit_sha: request.approved_commit_sha) do |root, manifest, sha, branch|
      raise Agents::GithubImportSource::Error, "Reviewed home identity changed" unless
        manifest["identity_id"] == request.portable_home_id && sha == request.commit_sha && branch == request.branch
      agent = request.agent
      unless agent
        # Checked again here, after the checkout: the switch may have gone on
        # while the repository was being fetched, and this is the point where
        # a home would be made on the house.
        if (refusal = Agents::VmBirthPolicy.current.refusal(kind: :import))
          request.update!(status: "failed", last_error: refusal)
          return
        end
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

end

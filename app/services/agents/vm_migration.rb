module Agents
  # Moving an existing house resident to its own server (#426, slice 3A).
  #
  # What it protects, and from whom: a living resident, from a move that loses
  # it. The move is the archive-import path with the resident's own home as
  # the archive, so it inherits that path's guarantees rather than restating
  # them:
  #
  # - stage! copies the home only from a stopped resident: the same
  #   Portability::Export that refuses unless it is inactive, paused and has no
  #   pending or uncertain turn, and that checks again after the copy. The
  #   copy is held as AgentImportStage rows (Portability::Stage), under the
  #   runner's seed limits, and the house volumes are left exactly as they
  #   were. Nothing is bought.
  # - The resident's runtime_ready_at moves onto its placement and is cleared
  #   on the agent, so every gate a VM birth has applies unchanged: no turn is
  #   dispatched on the server before its first verified backup
  #   (RemoteRuntime.enrollment_for), and ProvisionVmAgentJob sweeps it.
  # - activate! admits it under the same lock, switch and checks as a birth
  #   (VmBirthPolicy#admit_import!). It finishes with no orientation
  #   (ProvisionVmAgentJob#finish!).
  # - return_to_house! undoes a move that never finished, only once nothing
  #   could still be running on a server: staged, or retired after a failed
  #   attempt with no purchase unresolved and no backup hold. Lossless
  #   because, before cutover, the house home is the only home it has lived
  #   in. After cutover the move is undone by a later slice (copy-back).
  #
  # This class never starts a resident anywhere and never deletes a house
  # volume.
  class VmMigration

    class Refused < StandardError; end

    SWITCHED_OFF = "This house isn't creating resident servers right now, so residents can't move to their own " \
                   "server. Ask a site admin.".freeze
    NO_BACKUPS = "Residents can't move to their own server until VM backups are available here.".freeze
    NOT_CONFIGURED = "Server ordering isn't configured on this house. Ask a site admin.".freeze
    AT_LIMIT = "This house has reached its limit of resident servers. Ask a site admin.".freeze
    ALREADY_PLACED = "This resident is already on, or moving to, its own server.".freeze
    NEVER_LIVED = "Only a resident that has been running on the house can be moved.".freeze
    NOT_A_MIGRATION = "This resident isn't moving to its own server.".freeze
    CUT_OVER = "This resident already runs on its own server. Bringing it back from there is not built yet.".freeze
    STILL_RUNNING = "Its move can only be undone once nothing of it can be running on a server. Wait for its server " \
                    "to be released.".freeze

    def initialize(agent, policy: VmBirthPolicy.current)
      @agent = agent
      @policy = policy
    end

    attr_reader :agent

    # nil means it may be staged now. Checked in the order a person can act
    # on: the house first, then the resident.
    def refusal
      return SWITCHED_OFF unless @policy.enabled?
      return NO_BACKUPS unless @policy.vm_backups_available?
      return NOT_CONFIGURED unless @policy.procurement_configured?
      return AT_LIMIT if @policy.remaining <= 0

      placement = AgentPlacement.uncached { AgentPlacement.find_by(agent_id: agent.id) }
      return ALREADY_PLACED unless placement.nil? || (placement.backend == "local" && placement.state == "ready")
      return NEVER_LIVED if agent.runtime_ready_at.nil?

      Portability::Export.unavailable_reason(agent)
    end

    # Copies the stopped resident's home into stages and marks it as moving.
    # The whole copy runs under the resident's row lock, so nothing can start
    # it between the copy and the placement change. Returns the placement.
    def stage!(requested_by:, transport: Portability::Transport.new(agent))
      reason = refusal
      raise Refused, reason if reason

      placement = nil
      agent.with_lock do
        reason = refusal
        raise Refused, reason if reason

        Portability::Export.call(agent, exporter: requested_by, transport:) do |path|
          File.open(path, "rb") do |file|
            Portability::Archive.with_upload(file) do |archive|
              raise Refused, "The copy is not of this resident" unless archive.manifest["source_resident_id"] == agent.uuid

              Portability::Stage.persist!(archive, agent)
            end
          end
        end
        placement = AgentPlacement.find_or_initialize_by(agent:)
        house_ready_at = agent.runtime_ready_at
        placement.update!(backend: "hetzner_cloud", kind: "migration", state: "staged",
          generation: placement.persisted? ? placement.generation + 1 : 1, house_runtime_ready_at: house_ready_at)
        agent.update_columns(runtime_ready_at: nil, runtime: "offline", updated_at: Time.current)
        AuditLog.create!(action: "vm_migration_staged", user: requested_by, account: agent.account, auditable: agent,
          data: { "placement_id" => placement.id, "generation" => placement.generation,
                  "roles" => agent.import_stages.order(:role).map { |stage| { stage.role => stage.sha256 } } })
      end
      placement
    rescue Portability::Error => error
      raise Refused, error.message
    end

    # Admits a staged move (or a retry of a failed one) and starts provisioning.
    def activate!(requested_by:)
      placement = migration_placement!
      raise Refused, CUT_OVER if placement.state == "ready"

      retrying = %w[failed retired].include?(placement.state)
      begin
        @policy.admit_import!(placement:, requested_by:)
      rescue VmBirthPolicy::Refused => error
        raise Refused, error.message
      end
      AuditLog.create!(action: "vm_migration_admitted", user: requested_by, account: agent.account, auditable: agent,
        data: { "placement_id" => placement.id, "generation" => placement.reload.generation, "retry" => retrying })
      agent.update_columns(runtime: "provisioning", health_state: "unknown", sandbox_last_error: nil,
        sandbox_last_error_at: nil, updated_at: Time.current)
      ProvisionVmAgentJob.perform_later(agent.id)
      placement
    end

    # Puts a move that never finished back as it was: local placement (at the
    # next generation, which fences anything the server was sent), the
    # resident's runtime_ready_at, and no stages. It stays inactive and
    # paused; a person starts it on the house.
    def return_to_house!(requested_by:)
      placement = migration_placement!
      AgentPlacement.transaction do
        agent.lock!
        placement.lock!
        raise Refused, CUT_OVER if agent.runtime_ready_at.present? || placement.state == "ready"
        raise Refused, STILL_RUNNING unless placement.staged? || released?(placement)

        house_ready_at = placement.house_runtime_ready_at || raise(Refused, NEVER_LIVED)
        placement.update!(backend: "local", kind: nil, state: "ready", generation: placement.generation + 1,
          house_runtime_ready_at: nil, admitted_by_setting_at: nil, birth_deadline_at: nil, birth_requested_by: nil,
          cleanup_requested_at: nil, cleanup_reason: nil, first_backup_command_id: nil, provider_server_id: nil,
          location: nil, runtime_endpoint: nil, seeded_at: nil)
        agent.import_stages.delete_all
        agent.update_columns(runtime_ready_at: house_ready_at, active: false, paused: true, runtime: "offline",
          health_state: "unknown", sandbox_last_error: nil, sandbox_last_error_at: nil, updated_at: Time.current)
        AuditLog.create!(action: "vm_migration_returned_to_house", user: requested_by, account: agent.account,
          auditable: agent, data: { "placement_id" => placement.id, "generation" => placement.generation })
      end
      placement
    end

    private

    def migration_placement!
      placement = AgentPlacement.uncached { AgentPlacement.find_by(agent_id: agent.id) }
      raise Refused, NOT_A_MIGRATION unless placement&.migration?

      placement
    end

    # Nothing of it can be running anywhere: its server's deletion is
    # confirmed (retired), no purchase is unsettled and no backup holds it.
    def released?(placement)
      placement.state == "retired" &&
        !placement.cloud_procurement_operations.unresolved.exists? &&
        !(defined?(VmBackup) && VmBackup.holding.exists?(agent_id: placement.agent_id))
    end

  end
end

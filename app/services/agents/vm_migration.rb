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
  # - stage! also takes the carry (slice 3C): one restic snapshot of the
  #   stopped house chaos and state homes into the resident's own repository,
  #   with a shape digest per volume (CarrySnapshot). A carry that fails
  #   refuses the stage; nothing is staged without one.
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
    HOME_RELEASED = "Its house home has been released, so it can't be returned to the house this way.".freeze

    # One check a move must pass, and its current answer: nil when it passes.
    Gate = Data.define(:name, :refusal) do
      def ok? = refusal.nil?
    end

    # carry: (agent, generation) -> CarrySnapshot::Result. The house half of
    # the carry (checkpoint 2), taken inside stage!'s stopped window.
    CARRY = ->(agent, generation) { CarrySnapshot.new(agent, generation:).call }

    def initialize(agent, policy: VmBirthPolicy.current, carry: CARRY)
      @agent = agent
      @policy = policy
      @carry = carry
    end

    attr_reader :agent

    # nil means it may be staged now. Checked in the order a person can act
    # on: the house first, then the resident. Stops at the first refusal.
    def refusal
      gate_checks.each_value do |check|
        reason = check.call
        return reason if reason
      end
      nil
    end

    # Every gate with its current answer, in the same order, for a dry run
    # (slice 3B). Reads only.
    def gates
      gate_checks.map { |name, check| Gate.new(name:, refusal: check.call) }
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
        generation = placement.persisted? ? placement.generation + 1 : 1
        # Still stopped and still under the row lock: the chaos and state
        # homes go into its own repository, bound to this generation.
        carry = begin
          @carry.call(agent, generation)
        rescue CarrySnapshot::Failed => error
          raise Refused, error.message
        end
        house_ready_at = agent.runtime_ready_at
        placement.update!(backend: "hetzner_cloud", kind: "migration", state: "staged", generation:,
          house_runtime_ready_at: house_ready_at,
          carry: { "snapshot_id" => carry.snapshot_id, "generation" => generation, "tags" => carry.tags, "shapes" => carry.shapes })
        agent.update_columns(runtime_ready_at: nil, runtime: "offline", updated_at: Time.current)
        AuditLog.create!(action: "vm_migration_staged", user: requested_by, account: agent.account, auditable: agent,
          data: { "placement_id" => placement.id, "generation" => placement.generation,
                  "roles" => agent.import_stages.order(:role).map { |stage| { stage.role => stage.sha256 } },
                  "carry_snapshot_id" => carry.snapshot_id })
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

    # The operator's one call (slice 3B, rake and Site Admin): stage, then
    # admit. If admission refuses right after a fresh stage, the stage is
    # returned to the house at once, so a refused move leaves the resident as
    # it was (local, its runtime_ready_at back, no stages), still paused.
    def move!(requested_by:, transport: Portability::Transport.new(agent))
      stage!(requested_by:, transport:)
      begin
        activate!(requested_by:)
      rescue Refused
        return_to_house!(requested_by:)
        raise
      end
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
        # Starting it on volumes that are gone would give it an empty home.
        raise Refused, HOME_RELEASED if home_released?

        house_ready_at = placement.house_runtime_ready_at || raise(Refused, NEVER_LIVED)
        placement.update!(backend: "local", kind: nil, state: "ready", generation: placement.generation + 1,
          house_runtime_ready_at: nil, admitted_by_setting_at: nil, birth_deadline_at: nil, birth_requested_by: nil,
          cleanup_requested_at: nil, cleanup_reason: nil, first_backup_command_id: nil, provider_server_id: nil,
          location: nil, runtime_endpoint: nil, seeded_at: nil, carry: nil)
        agent.import_stages.delete_all
        agent.update_columns(runtime_ready_at: house_ready_at, active: false, paused: true, runtime: "offline",
          health_state: "unknown", sandbox_last_error: nil, sandbox_last_error_at: nil, updated_at: Time.current)
        AuditLog.create!(action: "vm_migration_returned_to_house", user: requested_by, account: agent.account,
          auditable: agent, data: { "placement_id" => placement.id, "generation" => placement.generation })
      end
      placement
    end

    private

    def gate_checks
      {
        "Resident servers switched on" => -> { SWITCHED_OFF unless @policy.enabled? },
        "VM backups available" => -> { NO_BACKUPS unless @policy.vm_backups_available? },
        "Server ordering configured" => -> { NOT_CONFIGURED unless @policy.procurement_configured? },
        "Below the resident server limit" => -> { AT_LIMIT if @policy.remaining <= 0 },
        "Runs on the house today" => lambda do
          placement = AgentPlacement.uncached { AgentPlacement.find_by(agent_id: agent.id) }
          ALREADY_PLACED unless placement.nil? || (placement.backend == "local" && placement.state == "ready")
        end,
        "Has lived on the house" => -> { NEVER_LIVED if agent.runtime_ready_at.nil? },
        "Stopped and can be copied" => -> { Portability::Export.unavailable_reason(agent) }
      }
    end

    def migration_placement!
      placement = AgentPlacement.uncached { AgentPlacement.find_by(agent_id: agent.id) }
      raise Refused, NOT_A_MIGRATION unless placement&.migration?

      placement
    end

    # Any volume it would run on at the house has had a release asked for.
    def home_released?
      names = Resources.new(agent).volumes.values
      AuditLog.where(action: HouseVolumeRelease::INTENDED, auditable_type: "Agent", auditable_id: agent.id)
        .where("data->>'volume' IN (?)", names).exists?
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

module Agents
  # Whether a new resident may be born now, when the site setting says new
  # residents go on their own VM (docs/2026-10-09-vm-hosted-new-residents.md).
  #
  # What it protects, and from whom: the site admin's isolation choice, from
  # quietly degrading. With the switch on, a resident either gets its own VM or
  # is refused with a plain reason before anything is committed. Nothing ever
  # falls back to the house. With the switch off this class says yes to
  # everything, so a single-server installation never meets it.
  #
  # With the switch on, a birth is admitted only when everything a VM birth
  # needs exists: VM backups (no resident is ready before its first verified
  # backup), configured procurement and room under the cap. Any model a local
  # resident can use runs on a VM too (house inference, account API keys,
  # subscription logins). An archive import is not refused here: it is staged
  # with no server, and admitted when it is activated
  # (docs/2026-10-10-vm-imports.md). A GitHub import is admitted at import,
  # by the same checks as a birth, because its runtime trust check needs its
  # server. The reasons are checked in order, so the one a person sees is
  # the one they can act on soonest. admit! re-checks under the procurement
  # admission lock and commits the placement in the same transaction, so two
  # births can't both take the last slot.
  class VmBirthPolicy

    class Refused < HostedProvisioning::ConfigurationError; end

    NOT_CONFIGURED_REFUSAL = "This house creates new residents on their own server, but server ordering " \
                             "isn't configured. Ask a site admin.".freeze
    LIMIT_REFUSAL = "This house creates new residents on their own server, and it has reached its limit " \
                    "of resident servers. Ask a site admin.".freeze
    NOT_AVAILABLE_REFUSAL = "This house creates new residents on their own server, and that isn't available " \
                            "yet. Ask a site admin.".freeze
    IMPORT_SWITCHED_OFF = "This resident runs on its own server, and this house isn't creating resident servers " \
                          "right now. It stays imported, inactive and paused. Ask a site admin.".freeze
    ALREADY_ACTIVATING = "This resident is already being started on its own server.".freeze
    # A migration (#426) says what is true of it: its home is still on the
    # house, untouched, and it waits paused there.
    MIGRATION_SWITCHED_OFF = "This resident is staged to move to its own server, and this house isn't creating " \
                             "resident servers right now. Its home is still on the house, untouched; it stays paused. " \
                             "Ask a site admin.".freeze
    MIGRATION_STILL_RELEASING = "Its last move to its own server failed, and that server is still being released. " \
                                "Try again in a few minutes. Its home is still on the house, untouched; it stays paused.".freeze
    # What admit_import! can admit again after a failed attempt. An archive
    # import is first admitted there too; a GitHub import first by admit!.
    IMPORT_KINDS = %w[archive_import github_import migration].freeze
    STILL_RELEASING = "Its last start on its own server failed, and that server is still being released. " \
                      "Try again in a few minutes. It stays imported, inactive and paused.".freeze
    # From admission to first verified backup. Past it the birth fails and its
    # server is cleaned up, so a stuck birth can't keep spending.
    BIRTH_DEADLINE = 45.minutes

    def self.current
      new(setting: Setting.instance)
    end

    def initialize(setting:, procurement_config: nil, api_token: nil)
      @setting = setting
      @procurement_config = procurement_config
      @api_token = api_token
    end

    def enabled?
      @setting.new_residents_on_vm?
    end

    # nil means yes. kind is :birth for a new resident, :archive_import for an
    # archive import (staged now, admitted at Activate, so nothing to refuse
    # yet) and :import for a GitHub import, which is checked as a birth.
    # model_id, when given, is the new resident's.
    def refusal(kind: :birth, model_id: nil)
      return nil unless enabled?
      return nil if kind == :archive_import
      return NOT_AVAILABLE_REFUSAL unless vm_backups_available?
      return NOT_CONFIGURED_REFUSAL unless procurement_configured?
      return LIMIT_REFUSAL if remaining <= 0

      nil
    end

    def refuse!(kind: :birth, model_id: nil)
      reason = refusal(kind: kind, model_id: model_id)
      raise Refused, reason if reason
    end

    # Commits the birth's agent and its VM placement together, under the
    # procurement admission lock, after checking again with the lock held.
    # The placement durably records that the switch admitted it; nothing
    # later re-reads the switch. Returns the placement.
    # kind is "birth", or "github_import" for a GitHub import admitted at
    # import (docs/2026-10-10-vm-imports.md, points 2 and 4). A block, given,
    # runs inside the same transaction once the placement exists: a GitHub
    # import records its staged home there, so an admitted import always has
    # one and a refused one leaves nothing.
    def admit!(agent:, requested_by:, kind: "birth", now: Time.current)
      raise ArgumentError, "unknown admission kind #{kind.inspect}" unless %w[birth github_import].include?(kind)

      AgentPlacement.transaction do
        AgentPlacement.connection.execute("SELECT pg_advisory_xact_lock(#{CloudProcurement::ADMISSION_LOCK})")
        @setting.reload
        raise Refused, NOT_AVAILABLE_REFUSAL unless enabled?

        refuse!(kind: :birth, model_id: agent.model_id)
        agent.uuid ||= SecureRandom.uuid_v7
        agent.save!
        placement = AgentPlacement.create!(agent:, backend: "hetzner_cloud", kind:, state: "pending",
          admitted_by_setting_at: now, birth_deadline_at: now + BIRTH_DEADLINE, birth_requested_by: requested_by)
        yield placement if block_given?
        placement
      end
    end

    # Activating an archive import staged for its own server
    # (docs/2026-10-10-vm-imports.md, points 2, 3, 8, 9): the same lock,
    # switch and checks as a birth, then the staged placement becomes a
    # pending one with its admission stamp, deadline and requester, which is
    # what lets ProvisionVmAgentJob and procurement act on it. A second
    # Activate, or one racing this, finds it no longer staged and is refused.
    # With the switch off nothing is admitted and the copy stays staged: it is
    # never run here instead.
    #
    # Pressing Activate again after a failed attempt (its deadline passed, or a
    # step failed) admits the same placement afresh, at its next generation,
    # but only once cleanup has confirmed the last server gone: the placement
    # is retired, no purchase is unresolved and no backup hold is left. Until
    # then the slot is still counted and the retry is refused, so a retry can
    # never overlap the server it replaces. The next generation fences the
    # last attempt's runner commands; its purchases stay as history. The
    # staged role homes are the same bytes. Returns the placement.
    def admit_import!(placement:, requested_by:, now: Time.current)
      AgentPlacement.transaction do
        AgentPlacement.connection.execute("SELECT pg_advisory_xact_lock(#{CloudProcurement::ADMISSION_LOCK})")
        @setting.reload
        migration = placement.kind == "migration"
        raise Refused, (migration ? MIGRATION_SWITCHED_OFF : IMPORT_SWITCHED_OFF) unless enabled?

        placement.lock!
        retry_attempt = retryable_import?(placement)
        if !retry_attempt && IMPORT_KINDS.include?(placement.kind) && %w[failed retired].include?(placement.state)
          raise Refused, (migration ? MIGRATION_STILL_RELEASING : STILL_RELEASING)
        end
        raise Refused, ALREADY_ACTIVATING unless placement.staged? || retry_attempt
        refuse!(kind: :birth)

        attributes = { state: "pending", admitted_by_setting_at: now, birth_deadline_at: now + BIRTH_DEADLINE,
                       birth_requested_by: requested_by }
        if retry_attempt
          attributes.merge!(generation: placement.generation + 1, cleanup_requested_at: nil, cleanup_reason: nil,
            first_backup_command_id: nil, provider_server_id: nil, location: nil, runtime_endpoint: nil)
        end
        placement.update!(attributes)
        placement
      end
    end

    # A failed archive activation whose server is confirmed gone. Read under
    # the placement lock by admit_import!.
    def retryable_import?(placement)
      return false unless placement.backend == "hetzner_cloud" && IMPORT_KINDS.include?(placement.kind)
      return false unless placement.state == "retired" && placement.agent.runtime_ready_at.nil?
      return false if placement.cloud_procurement_operations.unresolved.exists?
      return false if defined?(VmBackup) && VmBackup.holding.exists?(agent_id: placement.agent_id)

      true
    end

    # Slice 4 of #246: without VM backups no VM resident can become ready.
    def vm_backups_available?
      Backup.const_defined?(:VmResident)
    rescue NameError
      false
    end

    # Every server that might exist counts until its deletion is confirmed:
    # a VM placement that isn't retired, or any placement with a purchase
    # whose outcome isn't settled. A staged import has no server and no
    # purchase, so it holds no slot.
    def vm_count
      AgentPlacement.where(backend: "hetzner_cloud").where.not(state: %w[retired staged])
        .or(AgentPlacement.where(id: CloudProcurementOperation.unresolved.select(:agent_placement_id)))
        .count
    end

    def remaining
      [ @setting.vm_resident_limit - vm_count, 0 ].max
    end

    def procurement_configured?
      config = @procurement_config || CloudProcurement::Config.from_credentials
      token = @api_token || Rails.application.credentials.dig(:hetzner_cloud, :api_token)
      token.present? &&
        config.image_id.present? && config.ssh_key_ids.any? && config.locations.any? &&
        config.rails_url.present? && config.runner_commands
    rescue ArgumentError, TypeError
      false
    end

    # What Site Admin and the create form show.
    def as_json(*)
      {
        enabled: enabled?,
        limit: @setting.vm_resident_limit,
        vm_count: vm_count,
        procurement_configured: procurement_configured?,
        birth_refusal: refusal(kind: :birth),
        import_refusal: refusal(kind: :import)
      }
    end

  end
end

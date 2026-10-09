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
  # backup), configured procurement, room under the cap, and a model a VM can
  # run today. The reasons are checked in order, so the one a person sees is
  # the one they can act on soonest. admit! re-checks under the procurement
  # admission lock and commits the placement in the same transaction, so two
  # births can't both take the last slot.
  class VmBirthPolicy

    class Refused < HostedProvisioning::ConfigurationError; end

    IMPORT_REFUSAL = "This house creates new residents on their own server, and imported residents can't " \
                     "be created that way yet. A site admin can switch it off in Site Admin → Settings.".freeze
    SUBSCRIPTION_REFUSAL = "Residents on their own server can't use a subscription login yet. " \
                           "Use an API key or an on-the-house model.".freeze
    NOT_CONFIGURED_REFUSAL = "This house creates new residents on their own server, but server ordering " \
                             "isn't configured. Ask a site admin.".freeze
    LIMIT_REFUSAL = "This house creates new residents on their own server, and it has reached its limit " \
                    "of resident servers. Ask a site admin.".freeze
    NOT_AVAILABLE_REFUSAL = "This house creates new residents on their own server, and that isn't available " \
                            "yet. Ask a site admin.".freeze
    MODEL_REFUSAL = "Residents on their own server use an on-the-house model for now. Choose one, or ask a " \
                    "site admin.".freeze
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

    # nil means yes. kind is :birth for a new resident and :import for an
    # archive or GitHub import. model_id, when given, is the new resident's.
    def refusal(kind: :birth, model_id: nil)
      return nil unless enabled?
      return IMPORT_REFUSAL if kind == :import
      return MODEL_REFUSAL if model_id && !vm_model?(model_id)
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
    def admit!(agent:, requested_by:, now: Time.current)
      AgentPlacement.transaction do
        AgentPlacement.connection.execute("SELECT pg_advisory_xact_lock(#{CloudProcurement::ADMISSION_LOCK})")
        @setting.reload
        raise Refused, NOT_AVAILABLE_REFUSAL unless enabled?

        refuse!(kind: :birth, model_id: agent.model_id)
        agent.uuid ||= SecureRandom.uuid_v7
        agent.save!
        AgentPlacement.create!(agent:, backend: "hetzner_cloud", state: "pending", admitted_by_setting_at: now,
          birth_deadline_at: now + BIRTH_DEADLINE, birth_requested_by: requested_by)
      end
    end

    # A VM runs house-inference residents today (Agents::RemoteRuntime).
    def vm_model?(model_id)
      HouseInference::Offering.find(model_id.to_s).present?
    end

    # Slice 4 of #246: without VM backups no VM resident can become ready.
    def vm_backups_available?
      Backup.const_defined?(:VmResident)
    rescue NameError
      false
    end

    # Every server that might exist counts until its deletion is confirmed:
    # a VM placement that isn't retired, or any placement with a purchase
    # whose outcome isn't settled.
    def vm_count
      AgentPlacement.where(backend: "hetzner_cloud").where.not(state: "retired")
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

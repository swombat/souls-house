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
  # Slice 2 has no VM birth path yet, so with the switch on every birth is
  # refused. The reasons are checked in order, so the one a person sees is the
  # one they can act on soonest.
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
    # archive or GitHub import.
    def refusal(kind: :birth)
      return nil unless enabled?
      return IMPORT_REFUSAL if kind == :import
      return NOT_CONFIGURED_REFUSAL unless procurement_configured?
      return LIMIT_REFUSAL if remaining <= 0

      # Until the VM birth job exists (slice 5), there is no way to say yes.
      NOT_AVAILABLE_REFUSAL
    end

    def refuse!(kind: :birth)
      reason = refusal(kind: kind)
      raise Refused, reason if reason
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

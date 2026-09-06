class Mnemodyne::Erasure

  class Invalid < StandardError; end
  GRACE_PERIOD = 7.days

  def self.fingerprint(envelope)
    Digest::SHA256.hexdigest(JSON.generate(canonical(envelope.fetch("payload").slice("resident_uuid", "nodes", "edges", "settings"))))
  end

  def self.export_receipt(vault, envelope)
    verifier.generate({ "vault_id" => vault.id, "fingerprint" => fingerprint(envelope) },
      expires_in: 24.hours, purpose: "memory-erasure")
  end

  def self.request(vault, receipt:, confirmation:, include_constitutional: false)
    raise Invalid unless confirmation == vault.agent.uuid && confirmation.present?
    raise Invalid unless receipt.is_a?(String) && receipt.bytesize <= 20_000
    raise Invalid unless [ true, false ].include?(include_constitutional)
    data = verifier.verified(receipt, purpose: "memory-erasure")
    raise Invalid unless data && data["vault_id"] == vault.id
    vault.with_lock do
      raise Invalid if vault.suspended_at?
      current = fingerprint(Mnemodyne::Checkpoint.export(vault))
      raise Invalid unless data["fingerprint"] == current
      raise Invalid if vault.nodes.where(integration_state: "constitutional").exists? && !include_constitutional
      unless vault.erasure_requested_at?
        vault.update!(erasure_requested_at: Time.current, erase_after: GRACE_PERIOD.from_now,
          erasure_fingerprint: current, erase_constitutional: include_constitutional,
          recall_generation: vault.recall_generation + 1)
      end
    end
    vault
  end

  def self.cancel(vault)
    vault.with_lock do
      vault.update!(erasure_requested_at: nil, erase_after: nil, erasure_fingerprint: nil, erase_constitutional: false)
    end
  end

  def self.perform(vault)
    # Agent-before-vault order matches provisioning and prevents a fresh vault
    # being enabled concurrently with the final purge.
    vault.agent.with_lock do
      vault.with_lock do
        return false unless vault.erase_after && vault.erase_after <= Time.current
        if vault.suspended_at?
          Rails.logger.warn("Mnemodyne erasure held: vault suspended")
          return false
        end
        raise Invalid unless vault.erasure_fingerprint == fingerprint(Mnemodyne::Checkpoint.export(vault))
        raise Invalid if vault.nodes.where(integration_state: "constitutional").exists? && !vault.erase_constitutional?
        [ Mnemodyne::Use, Mnemodyne::Operation, Mnemodyne::Edge, Mnemodyne::Node ].each do |model|
          model.where(vault_id: vault.id).delete_all
        end
        vault.agent.update!(memory_erased_at: Time.current)
        # Already empty, deliberate final erasure; ordinary destruction remains restricted.
        vault.destroy!
      end
    end
    true
  end

  def self.verifier
    Rails.application.message_verifier("mnemodyne-erasure")
  end
  private_class_method :verifier

  def self.canonical(value)
    case value
    when Hash then value.stringify_keys.sort.to_h.transform_values { |child| canonical(child) }
    when Array then value.map { |child| canonical(child) }
    else value
    end
  end
  private_class_method :canonical

end

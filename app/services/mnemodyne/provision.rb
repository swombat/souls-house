class Mnemodyne::Provision

  def self.call(agent, deliberate: false)
    return unless agent.externally_hosted? && agent.active? && !agent.account.disabled?
    agent.with_lock do
      agent.memory_vault || (agent.create_memory_vault!(auto_preview_enabled: true) unless agent.memory_erased_at? && !deliberate)
    end
  end

end

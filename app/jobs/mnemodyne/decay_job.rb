class Mnemodyne::DecayJob < ApplicationJob

  def perform
    Mnemodyne::Vault.where(suspended_at: nil, erasure_requested_at: nil).find_each do |vault|
      next unless vault.agent.externally_hosted? && vault.agent.active? && !vault.agent.account.disabled?
      vault.with_lock do
        next if vault.erasure_requested_at? || vault.suspended_at?
        next if vault.last_decay_on == Date.current
        rate = vault.decay_rate
        vault.nodes.active.find_each do |node|
          next if node.decay_exempt?
          # Decay never raises an intentionally low charge to the floor.
          node.update!(charge: [ [ node.charge - vault.charge_decay_rate, vault.charge_decay_floor ].max, node.charge ].min)
        end
        vault.edges.update_all([ "weight = GREATEST(weight - ?, 0)", rate ])
        vault.uses.where("expires_at < ?", 1.day.ago).delete_all
        vault.update!(last_decay_on: Date.current)
      end
    end
  end

end

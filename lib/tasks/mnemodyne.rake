namespace :mnemodyne do
  desc "Check the configured private embedding service with synthetic text"
  task check: :environment do
    vector = Mnemodyne::Embeddings.embed("Synthetic Mnemodyne deployment readiness probe")
    puts "Mnemodyne embeddings ready: profile=#{Mnemodyne::Embeddings.profile}, dimensions=#{vector.length}"
  end

  desc "Queue re-embedding for active resident vaults (optional RESIDENT_ID)"
  task reembed: :environment do
    abort "Configure the embedding service first" unless Mnemodyne::Embeddings.configured?
    scope = Mnemodyne::Vault.where(suspended_at: nil, erasure_requested_at: nil)
    scope = scope.where(agent: Agent.find(ENV.fetch("RESIDENT_ID"))) if ENV["RESIDENT_ID"].present?
    count = 0
    scope.find_each do |vault|
      next unless vault.agent.externally_hosted? && vault.agent.active? && !vault.agent.account.disabled?
      vault.nodes.find_each do |node|
        Mnemodyne::EmbedNodeJob.perform_later(vault.id, node.id)
        count += 1
      end
    end
    puts "Queued #{count} nodes for the configured profile; no graph was provisioned or seeded"
  end
end

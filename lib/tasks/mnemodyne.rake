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
    vaults = 0
    nodes = 0
    profile = Mnemodyne::Embeddings.profile
    scope.find_each do |vault|
      next unless vault.agent.externally_hosted? && vault.agent.active? && !vault.agent.account.disabled?
      stale = vault.nodes.count { |node| !Mnemodyne::ReembedVaultJob.current?(node, profile) }
      next if stale.zero?
      Mnemodyne::ReembedVaultJob.perform_later(vault.id)
      vaults += 1
      nodes += stale
    end
    puts "Queued #{vaults} vaults (#{nodes} nodes not yet on #{profile}); no graph was provisioned or seeded"
  end

  desc "Count, per vault, nodes and nodes embedded under the configured profile (counts only)"
  task coverage: :environment do
    profile = Mnemodyne::Embeddings.profile
    puts "profile=#{profile} configured=#{Mnemodyne::Embeddings.configured?}"
    Mnemodyne::Vault.where(erasure_requested_at: nil).find_each do |vault|
      total = vault.nodes.count
      next if total.zero?
      current = vault.nodes.count { |node| Mnemodyne::ReembedVaultJob.current?(node, profile) }
      other = vault.nodes.where.not(embedding: nil).where.not(embedding_profile: profile).count
      puts "resident=#{vault.agent_id} nodes=#{total} current=#{current} missing=#{total - current} other_profile=#{other}"
    end
  end
end

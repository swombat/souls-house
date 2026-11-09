class Mnemodyne::ReembedVaultJob < ApplicationJob

  # Shares the single embeddings slot with EmbedNodeJob, so a vault re-embed
  # and per-node jobs never race the provider together.
  limits_concurrency to: 1, key: "mnemodyne-embeddings"

  # A retry resumes: nodes already embedded under the current profile are
  # skipped, so only what is left is sent again.
  retry_on Mnemodyne::Embeddings::Unavailable, wait: :polynomially_longer, attempts: 5

  def perform(vault_id)
    vault = Mnemodyne::Vault.find_by(id: vault_id)
    return unless vault && Mnemodyne::Embeddings.configured?
    return if vault.suspended_at? || vault.erasure_requested_at?
    profile = Mnemodyne::Embeddings.profile
    stale = vault.nodes.reject { |node| self.class.current?(node, profile) }
    unless Mnemodyne::Embeddings.batched?
      stale.each { |node| Mnemodyne::EmbedNodeJob.perform_later(vault.id, node.id) }
      return
    end
    return if vault.agent.account.disabled? || !vault.agent.externally_hosted?
    stale.each_slice(Mnemodyne::Embeddings::BATCH_SIZE) do |batch|
      texts = batch.map(&:embedding_text)
      vectors = Mnemodyne::Embeddings.embed_many(texts, input_type: :document)
      vault.with_lock do
        return if vault.erasure_requested_at? || vault.suspended_at? || vault.agent.reload.account.disabled?
        return unless Mnemodyne::Embeddings.profile == profile
        batch.zip(texts, vectors).each do |(stale_node, text, vector)|
          node = vault.nodes.find_by(id: stale_node.id)
          # A node edited meanwhile has its own EmbedNodeJob; never store a vector for old text.
          next unless node && node.embedding_text == text
          node.update_columns(embedding: vector, embedding_digest: Digest::SHA256.hexdigest(text), embedding_profile: profile)
        end
      end
    end
  end

  def self.current?(node, profile)
    node.embedding.present? && node.embedding_profile == profile &&
      node.embedding_digest == Digest::SHA256.hexdigest(node.embedding_text)
  end

end

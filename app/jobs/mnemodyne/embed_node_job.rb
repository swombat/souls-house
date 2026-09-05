class Mnemodyne::EmbedNodeJob < ApplicationJob

  retry_on Mnemodyne::Embeddings::Unavailable, wait: :polynomially_longer, attempts: 3

  def perform(vault_id, node_id)
    vault = Mnemodyne::Vault.find_by(id: vault_id)
    return unless vault
    return if vault.suspended_at? || vault.agent.account.disabled? || !vault.agent.externally_hosted?
    node = vault.nodes.find_by(id: node_id)
    return unless node && Mnemodyne::Embeddings.configured?
    text = node.embedding_text
    digest = Digest::SHA256.hexdigest(text)
    profile = Mnemodyne::Embeddings.profile
    vector = Mnemodyne::Embeddings.embed(text)
    vault.with_lock do
      return if vault.suspended_at? || vault.agent.reload.account.disabled?
      node = vault.nodes.find_by(id: node_id)
      return unless node
      node.with_lock do
        return unless node.embedding_text == text && Mnemodyne::Embeddings.profile == profile
        node.update_columns(embedding: vector, embedding_digest: digest, embedding_profile: profile)
      end
    end
  end

end

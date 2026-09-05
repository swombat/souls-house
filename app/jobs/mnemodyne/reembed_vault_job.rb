class Mnemodyne::ReembedVaultJob < ApplicationJob

  def perform(vault_id)
    vault = Mnemodyne::Vault.find_by(id: vault_id)
    return unless vault && Mnemodyne::Embeddings.configured?
    return if vault.suspended_at? || vault.erasure_requested_at?
    vault.nodes.find_each { |node| Mnemodyne::EmbedNodeJob.perform_later(vault.id, node.id) }
  end

end

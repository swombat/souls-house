class Mnemodyne::Commit

  class InvalidReceipt < StandardError; end

  def self.call(vault:, receipt:, selected_node_ids:, reason:)
    raise InvalidReceipt unless receipt.is_a?(String) && receipt.bytesize <= 20_000
    raise InvalidReceipt unless selected_node_ids.is_a?(Array) && selected_node_ids.length.between?(1, 5)
    raise InvalidReceipt unless %w[source_opened explicit_use explicit_recall].include?(reason)
    data = Rails.application.message_verifier("mnemodyne-recall").verified(receipt, purpose: "mnemodyne-use")
    raise InvalidReceipt unless data && data["vault_id"] == vault.id && data["version"] == Mnemodyne::Recall::VERSION
    selected = selected_node_ids.uniq
    raise InvalidReceipt unless (selected - data.fetch("deltas").keys).empty?
    vault.with_lock do
      raise InvalidReceipt if vault.erasure_requested_at? || vault.suspended_at?
      raise InvalidReceipt unless data["generation"] == vault.recall_generation
      selected.map do |id|
        node = vault.nodes.find(id)
        previous = vault.uses.find_by(recall_id: data.fetch("recall_id"), node_id: id)
        next { id: id, applied_reinforcement: previous.delta, replayed: true } if previous
        delta = node.is_dormant? ? 0.0 : [ data.fetch("deltas").fetch(id), 1.0 - node.charge ].min
        node.update!(charge: node.charge + delta) if delta.positive?
        vault.uses.create!(recall_id: data.fetch("recall_id"), node: node, delta: delta,
          reason: reason, expires_at: data.fetch("expires_at"))
        { id: id, applied_reinforcement: delta, replayed: false }
      end
    end
  end

end

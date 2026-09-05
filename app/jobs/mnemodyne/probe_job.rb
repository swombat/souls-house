class Mnemodyne::ProbeJob < ApplicationJob

  def perform
    raise Mnemodyne::Embeddings::Unavailable unless Mnemodyne::Embeddings.configured?
    Mnemodyne::Embeddings.embed("Synthetic Mnemodyne readiness probe")
  rescue Mnemodyne::Embeddings::Unavailable => error
    Rails.logger.error("Mnemodyne embedding readiness failed")
    Rails.error.report(error, handled: false, context: { subsystem: "mnemodyne_embeddings" })
    raise # Also visible as a failed Solid Queue job, not a green probe.
  end

end

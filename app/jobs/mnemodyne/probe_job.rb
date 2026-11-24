class Mnemodyne::ProbeJob < ApplicationJob

  def perform
    raise Mnemodyne::Embeddings::Unavailable.new(:not_configured), cause: nil unless Mnemodyne::Embeddings.configured?
    Mnemodyne::Embeddings.embed("Synthetic Mnemodyne readiness probe")
  rescue Mnemodyne::Embeddings::Unavailable => error
    # The message is the reason ("... unavailable: rate_limited (429)"), so the
    # failed Solid Queue row says Voyage from us without a log search.
    Rails.logger.error("Mnemodyne embedding readiness failed: #{error.message}")
    Rails.error.report(error, handled: false, context: { subsystem: "mnemodyne_embeddings", **error.context })
    raise # Also visible as a failed Solid Queue job, not a green probe.
  end

end

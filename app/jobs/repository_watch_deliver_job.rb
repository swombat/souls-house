# The effects of a fulfilled (or expired) watch: one factual line in the
# room, then one wake per resident who asked. Every effect is recorded on the
# RepositoryWatchDelivery row in the transaction that performs it, and
# checked before it is attempted, so a retry after any partial success
# neither posts nor wakes twice. Authority is checked again here: a room that
# may no longer receive the repository gets nothing, and the watch says why.
class RepositoryWatchDeliverJob < ApplicationJob

  queue_as :default
  limits_concurrency to: 1, key: ->(watch_id) { "repository-watch-deliver-#{watch_id}" }
  retry_on StandardError, wait: :polynomially_longer, attempts: 8

  def perform(watch_id)
    watch = RepositoryWatch.find_by(id: watch_id)
    return unless watch && watch.state.in?(%w[fulfilled expired])

    delivery = watch.repository_watch_deliveries.find_by(fulfilment_key: watch.fulfilment_key)
    return if delivery.nil? || delivery.completed?

    delivery.increment!(:attempts)
    begin
      deliver(watch, delivery)
    rescue StandardError => error
      delivery.update_columns(last_error: "#{error.class.name}: #{error.message}".truncate(200), updated_at: Time.current)
      raise
    end
  end

  private

  def deliver(watch, delivery)
    if (refusal = RepositoryWatches::Authority.fire_refusal(watch))
      watch.mark_undeliverable!(refusal)
      delivery.update!(last_error: refusal.truncate(200), completed_at: Time.current)
      return
    end

    post_once(watch, delivery)
    wake_once(watch, delivery) if watch.state == "fulfilled"
    delivery.update!(completed_at: Time.current, last_error: nil)
  end

  def post_once(watch, delivery)
    RepositoryWatchDelivery.transaction do
      delivery.lock!
      next if delivery.message_id.present?

      message = watch.chat.messages.create!(role: "system", content: watch.delivered_text)
      delivery.update!(message: message)
    end
  end

  # Through the held-wake path (#252): a resident who is free now is woken
  # now; one who is mid-run gets one wake when that run ends. The wake's
  # authority is the resident's own request, standing while it is in the room.
  def wake_once(watch, delivery)
    watch.wake_agents.each do |agent|
      RepositoryWatchDelivery.transaction do
        delivery.lock!
        next if delivery.woken?(agent.id)

        outcome = begin
          watch.chat.request_agent_response!(agent,
                                             requested_by: "a repository watch on #{watch.watched_repository.full_name}",
                                             requester_agent: agent).to_s
        rescue Agent::RuntimeAvailability::Unavailable => error
          "skipped: #{error.code}"
        rescue ArgumentError => error
          "skipped: #{error.message}".truncate(120)
        end
        delivery.update!(woken: delivery.woken.to_h.merge(agent.id.to_s => outcome))
      end
    end
  end

end

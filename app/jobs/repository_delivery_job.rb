# Acts on one verified, deduplicated webhook delivery: finds the armed
# watches it satisfies and fulfils each (RepositoryWatch#fulfil!, the one
# idempotent path).
class RepositoryDeliveryJob < ApplicationJob

  queue_as :default
  limits_concurrency to: 1, key: ->(delivery_id) { "repository-delivery-#{delivery_id}" }

  # Processing is safe to repeat: fulfil! acts only on armed watches, so a
  # receipt replayed by the sweep (RepositoryWatchSweepJob) or a redelivery
  # after a crash changes nothing that already happened.
  def perform(delivery_id)
    delivery = RepositoryDelivery.find_by(id: delivery_id)
    return unless delivery && delivery.signature_ok? && delivery.processed_at.nil?

    delivery.increment!(:process_attempts)
    process(delivery)
  rescue StandardError => error
    delivery&.update_columns(last_error: "#{error.class.name}: #{error.message}".truncate(200), updated_at: Time.current)
    raise
  end

  private

  def process(delivery)
    repository = delivery.watched_repository
    payload = delivery.payload.to_h
    case delivery.event
    when "workflow_run"
      run = payload["workflow_run"].to_h
      if delivery.action == "completed"
        candidates(repository, "workflow_run").each do |watch|
          next unless watch.matches_workflow_run?(run)

          watch.fulfil!(RepositoryWatch.workflow_fulfilment(run, source: "webhook").merge("delivery" => delivery.delivery_guid))
        end
      end
    when "deployment_status"
      status = payload["deployment_status"].to_h
      deployment = status["deployment"].to_h
      candidates(repository, "deployment_status").each do |watch|
        next unless watch.matches_deployment_status?(status, deployment)

        watch.fulfil!(RepositoryWatch.deployment_fulfilment(status, deployment, source: "webhook").merge("delivery" => delivery.delivery_guid))
      end
    end
    delivery.update!(processed_at: Time.current, last_error: nil)
  end

  def candidates(repository, event_kind)
    repository.repository_watches.armed.where(event_kind: event_kind).order(:id).to_a
  end

end

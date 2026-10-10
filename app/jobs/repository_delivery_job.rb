# Acts on one verified, deduplicated webhook delivery: finds the armed
# watches it satisfies and fulfils each (RepositoryWatch#fulfil!, the one
# idempotent path).
class RepositoryDeliveryJob < ApplicationJob

  queue_as :default

  def perform(delivery_id)
    delivery = RepositoryDelivery.find_by(id: delivery_id)
    return unless delivery && delivery.signature_ok? && delivery.processed_at.nil?

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
    delivery.update!(processed_at: Time.current)
  end

  private

  def candidates(repository, event_kind)
    repository.repository_watches.armed.where(event_kind: event_kind).order(:id).to_a
  end

end

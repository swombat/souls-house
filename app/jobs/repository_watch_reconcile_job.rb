# After a watch is armed (and again from the sweep while its status could
# not be established): ask GitHub whether what it waits for has already
# happened. A match fulfils through the same path as a webhook. A GitHub
# error means "status not established", never "still running".
class RepositoryWatchReconcileJob < ApplicationJob

  queue_as :default
  limits_concurrency to: 1, key: ->(watch_id) { "repository-watch-reconcile-#{watch_id}" }

  def perform(watch_id)
    watch = RepositoryWatch.find_by(id: watch_id)
    return unless watch&.armed?

    repository = watch.watched_repository
    client = RepositoryWatches::GithubClient.new(repository.service_connection)
    fulfilment = case watch.event_kind
    when "workflow_run" then workflow_match(client, repository, watch)
    when "deployment_status" then deployment_match(client, repository, watch)
    end

    if fulfilment
      watch.fulfil!(fulfilment)
    else
      watch.update_columns(reconcile_status: "done", reconcile_error: nil, updated_at: Time.current) if watch.reload.armed?
    end
  rescue RepositoryWatches::GithubClient::Error => error
    watch.update_columns(reconcile_status: "error", reconcile_error: error.message.truncate(200), updated_at: Time.current) if watch&.reload&.armed?
  end

  private

  def workflow_match(client, repository, watch)
    runs = client.workflow_runs(repository.full_name, head_sha: watch.head_sha)
    run = runs.select { |candidate| watch.matches_workflow_run?(candidate) }
      .max_by { |candidate| [ candidate["updated_at"].to_s, candidate["run_attempt"].to_i ] }
    run && RepositoryWatch.workflow_fulfilment(run, source: "reconcile")
  end

  def deployment_match(client, repository, watch)
    deployments = client.deployments(repository.full_name, sha: watch.head_sha, environment: watch.filter["environment"])
    deployments.each do |deployment|
      latest = client.deployment_statuses(repository.full_name, deployment["id"]).first
      next unless latest

      latest = latest.merge("environment" => latest["environment"].presence || deployment["environment"])
      return RepositoryWatch.deployment_fulfilment(latest, deployment, source: "reconcile") if watch.matches_deployment_status?(latest, deployment)
    end
    nil
  end

end

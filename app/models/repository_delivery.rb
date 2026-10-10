# One webhook delivery GitHub sent, by its X-GitHub-Delivery GUID. The unique
# GUID is the receipt dedup; the fulfilment of a watch has its own guard
# (RepositoryWatchDelivery), because a redelivery is not the only way the
# same fact can arrive twice. Only the fields we read are kept, never the raw
# body.
class RepositoryDelivery < ApplicationRecord

  belongs_to :watched_repository

  validates :delivery_guid, :event, :received_at, presence: true

  # The fields kept from a payload, by event. Everything else is dropped.
  def self.reduce_payload(event, payload)
    payload = payload.to_h
    base = { "repository" => payload.dig("repository", "full_name") }
    case event
    when "workflow_run"
      run = payload["workflow_run"].to_h
      base.merge("workflow_run" => run.slice("id", "run_attempt", "name", "head_sha", "status", "conclusion", "html_url"))
    when "deployment_status"
      status = payload["deployment_status"].to_h
      deployment = payload["deployment"].to_h
      base.merge("deployment_status" => status.slice("id", "state", "environment", "target_url", "log_url")
        .merge("deployment" => deployment.slice("id", "sha", "environment")))
    else
      base
    end
  end

end

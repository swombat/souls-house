require "test_helper"
require "support/repository_watch_helpers"

class RepositoryWebhooksControllerTest < ActionDispatch::IntegrationTest

  include RepositoryWatchHelpers
  include ActiveJob::TestHelper

  setup { build_watch_world }

  def workflow_body(run = completed_run)
    { action: "completed", workflow_run: run, repository: { full_name: "swombat/other-repo" }, sender: { login: "x" } }.to_json
  end

  def deliver(body, **headers)
    post repository_webhook_url(receiver_token: @repository.receiver_token), params: body, headers: signed_headers(body, **headers)
  end

  test "a signed delivery is recorded (reduced) and processed once; a redelivery is acknowledged, not redone" do
    body = workflow_body
    assert_enqueued_jobs 1, only: RepositoryDeliveryJob do
      deliver(body, event: "workflow_run", guid: "guid-1")
      deliver(body, event: "workflow_run", guid: "guid-1")
    end
    assert_response :ok
    delivery = @repository.repository_deliveries.sole
    assert_equal [ "guid-1", "workflow_run", "completed", true ], [ delivery.delivery_guid, delivery.event, delivery.action, delivery.signature_ok ]
    refute delivery.payload.key?("sender"), "only the fields we read are kept"
    assert_equal SHA, delivery.payload.dig("workflow_run", "head_sha")
    assert_equal "verified", @repository.reload.last_delivery_result
  end

  test "the acceptance flow: delivered twice, resident mid-run, one line and one held wake" do
    AgentRuntimeInteraction.reserve!(agent: @resident, chat: @chat)
    @account.update!(use_system_ai_credentials: false, openrouter_api_key: "test-only-router")
    watch = arm_watch
    body = workflow_body
    perform_enqueued_jobs(only: [ RepositoryDeliveryJob, RepositoryWatchDeliverJob ]) do
      deliver(body, event: "workflow_run", guid: "same-guid")
      deliver(body, event: "workflow_run", guid: "same-guid")
    end
    assert_equal "fulfilled", watch.reload.state
    assert_equal 1, @chat.messages.where(role: "system").where("content LIKE ?", "swombat/other-repo%").count
    assert_equal 1, PendingWake.open.where(chat: @chat, agent: @resident).sole.sources.count
  end

  test "a wrong signature is 401 and recorded as rejected" do
    body = workflow_body
    post repository_webhook_url(receiver_token: @repository.receiver_token), params: body,
                                                                              headers: signed_headers(body, event: "workflow_run", secret: "not-the-secret")
    assert_response :unauthorized
    assert_equal "rejected", @repository.reload.last_delivery_result
    assert_equal 0, RepositoryDelivery.count
  end

  test "a missing signature is 401" do
    body = workflow_body
    headers = signed_headers(body, event: "workflow_run").except("X-Hub-Signature-256")
    post repository_webhook_url(receiver_token: @repository.receiver_token), params: body, headers: headers
    assert_response :unauthorized
  end

  test "an unknown or removed receiver token is 404 with nothing said" do
    post repository_webhook_url(receiver_token: "nope"), params: "{}", headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :not_found
    assert_empty response.body

    @repository.update_columns(removed_at: Time.current, hook_status: "removed")
    deliver(workflow_body, event: "workflow_run")
    assert_response :not_found
  end

  test "an oversized body is refused before the app reads it" do
    body = { padding: "x" * (RepositoryWebhookBodyLimit::MAX_BODY_BYTES + 10) }.to_json
    deliver(body, event: "workflow_run")
    assert_response :content_too_large
    assert_equal 0, RepositoryDelivery.count
  end

  test "a signed ping promotes a manual hook to installed" do
    @repository.update!(hook_status: "manual")
    deliver({ zen: "Keep it logically awesome.", hook_id: 1 }.to_json, event: "ping")
    assert_response :ok
    assert_equal "installed", @repository.reload.hook_status
  end

  test "other events are recorded as ignored and not processed" do
    assert_no_enqueued_jobs(only: RepositoryDeliveryJob) do
      deliver({ ref: "refs/heads/master" }.to_json, event: "push")
    end
    assert_equal "ignored", @repository.reload.last_delivery_result
  end

end

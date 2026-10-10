require "test_helper"
require "support/repository_watch_helpers"

class RepositoryWatchJobsTest < ActiveSupport::TestCase

  include RepositoryWatchHelpers
  include ActiveJob::TestHelper

  setup do
    build_watch_world
    @account.update!(use_system_ai_credentials: false, openrouter_api_key: "test-only-router")
  end

  def fulfilled_watch(**options)
    watch = arm_watch(**options)
    watch.fulfil!(RepositoryWatch.workflow_fulfilment(completed_run, source: "webhook"))
    watch.reload
  end

  def house_lines
    @chat.messages.where(role: "system").where("content LIKE ?", "swombat/other-repo%")
  end

  # --- deliver --------------------------------------------------------------

  test "deliver posts one house line and holds one wake for a resident mid-run" do
    AgentRuntimeInteraction.reserve!(agent: @resident, chat: @chat)
    watch = fulfilled_watch

    assert_difference -> { PendingWake.open.where(chat: @chat, agent: @resident).count }, 1 do
      RepositoryWatchDeliverJob.perform_now(watch.id)
    end
    delivery = watch.repository_watch_deliveries.sole
    assert_equal 1, house_lines.count
    assert_nil house_lines.sole.agent_id
    assert_equal house_lines.sole, delivery.message
    assert_equal "queued", delivery.woken[@resident.id.to_s]
    assert delivery.completed?
  end

  test "running deliver again after it completed posts and wakes nothing more" do
    AgentRuntimeInteraction.reserve!(agent: @resident, chat: @chat)
    watch = fulfilled_watch
    RepositoryWatchDeliverJob.perform_now(watch.id)

    assert_no_difference [ -> { house_lines.count }, -> { PendingWakeSource.count } ] do
      RepositoryWatchDeliverJob.perform_now(watch.id)
    end
  end

  test "a retry after the post succeeded but the wake failed posts nothing new and wakes once" do
    AgentRuntimeInteraction.reserve!(agent: @resident, chat: @chat)
    watch = fulfilled_watch

    original = Chat.instance_method(:request_agent_response!)
    Chat.define_method(:request_agent_response!) { |*, **| raise ActiveRecord::ConnectionTimeoutError, "transient" }
    begin
      assert_raises(ActiveRecord::ConnectionTimeoutError) { RepositoryWatchDeliverJob.new.perform(watch.id) }
    ensure
      Chat.define_method(:request_agent_response!, original)
    end

    delivery = watch.repository_watch_deliveries.sole
    assert delivery.message_id, "the line was posted before the wake failed"
    refute delivery.completed?
    assert_match(/transient/, delivery.last_error)

    assert_no_difference -> { house_lines.count } do
      assert_difference -> { PendingWakeSource.count }, 1 do
        RepositoryWatchDeliverJob.perform_now(watch.id)
      end
    end
    assert_equal 1, house_lines.count
    assert delivery.reload.completed?
    assert_equal 2, delivery.attempts
  end

  test "a crash after the wake was recorded but before completion does not wake again" do
    AgentRuntimeInteraction.reserve!(agent: @resident, chat: @chat)
    watch = fulfilled_watch
    RepositoryWatchDeliverJob.perform_now(watch.id)
    delivery = watch.repository_watch_deliveries.sole
    delivery.update_columns(completed_at: nil)

    assert_no_difference [ -> { house_lines.count }, -> { PendingWakeSource.count } ] do
      RepositoryWatchDeliverJob.perform_now(watch.id)
    end
    assert delivery.reload.completed?
  end

  test "a transient failure posting the line is retried, and the line appears once" do
    watch = fulfilled_watch(wake: false)
    failures = 1
    fail_once = proc { if failures.positive? then failures -= 1; raise ActiveRecord::Deadlocked, "transient" end }
    Message.set_callback(:create, :before, fail_once)
    begin
      assert_raises(ActiveRecord::Deadlocked) { RepositoryWatchDeliverJob.new.perform(watch.id) }
      assert_nil watch.repository_watch_deliveries.sole.message_id
      RepositoryWatchDeliverJob.new.perform(watch.id)
      RepositoryWatchDeliverJob.new.perform(watch.id)
    ensure
      Message.skip_callback(:create, :before, fail_once)
    end
    assert_equal 1, house_lines.count
  end

  test "grant revoked between arm and fire: undeliverable, nothing posted, nobody woken" do
    watch = fulfilled_watch
    @resident.agent_service_accesses.update_all(enabled: false)

    assert_no_difference [ -> { house_lines.count }, -> { PendingWakeSource.count } ] do
      RepositoryWatchDeliverJob.perform_now(watch.id)
    end
    assert_equal "undeliverable", watch.reload.state
    assert_match(/no longer holds a grant/, watch.undeliverable_reason)
  end

  test "a guest resident joining before the fire makes it undeliverable" do
    watch = fulfilled_watch
    guest = accounts(:team_account).agents.create!(name: "Guest", system_prompt: "Test", runtime: "external")
    @account.guest_memberships.create!(agent: guest, added_by: @user)
    @chat.agents << guest

    RepositoryWatchDeliverJob.perform_now(watch.id)
    assert_equal "undeliverable", watch.reload.state
    assert_equal 0, house_lines.count
  end

  # --- webhook delivery processing -----------------------------------------

  test "the same fact arriving twice (two deliveries) fulfils once: one line, one wake" do
    AgentRuntimeInteraction.reserve!(agent: @resident, chat: @chat)
    watch = arm_watch
    2.times do |index|
      delivery = @repository.repository_deliveries.create!(
        delivery_guid: "guid-#{index}", event: "workflow_run", action: "completed", received_at: Time.current,
        signature_ok: true, payload: { "workflow_run" => completed_run }
      )
      perform_enqueued_jobs(only: RepositoryWatchDeliverJob) { RepositoryDeliveryJob.perform_now(delivery.id) }
    end
    assert_equal "fulfilled", watch.reload.state
    assert_equal 1, house_lines.count
    assert_equal 1, PendingWakeSource.joins(:pending_wake).where(pending_wakes: { chat_id: @chat.id, agent_id: @resident.id }).count
  end

  test "a non-matching or unfinished run leaves the watch armed" do
    watch = arm_watch
    [ completed_run(sha: OTHER_SHA), completed_run.merge("status" => "in_progress") ].each_with_index do |run, index|
      delivery = @repository.repository_deliveries.create!(
        delivery_guid: "guid-x#{index}", event: "workflow_run", action: index.zero? ? "completed" : "in_progress",
        received_at: Time.current, signature_ok: true, payload: { "workflow_run" => run }
      )
      RepositoryDeliveryJob.perform_now(delivery.id)
      assert delivery.reload.processed_at
    end
    assert watch.reload.armed?
  end

  test "a deployment status delivery fulfils a deployment watch" do
    watch = arm_watch(event_kind: "deployment_status", filter: { "environment" => "production" }, wake: false)
    payload = RepositoryDelivery.reduce_payload("deployment_status", {
      "deployment_status" => { "id" => 9, "state" => "success", "environment" => "production", "target_url" => "https://example.com/deploys/9" },
      "deployment" => { "id" => 5, "sha" => SHA, "environment" => "production" }
    })
    delivery = @repository.repository_deliveries.create!(delivery_guid: "dep-1", event: "deployment_status", action: "created",
                                                         received_at: Time.current, signature_ok: true, payload: payload)
    RepositoryDeliveryJob.perform_now(delivery.id)
    assert_equal "fulfilled", watch.reload.state
    assert_equal "swombat/other-repo · deployment to production: success for a1b2c3d · https://example.com/deploys/9", watch.delivered_text
  end

  # --- reconcile ------------------------------------------------------------

  test "reconcile: CI already finished before the watch, fulfilled with source reconcile" do
    watch = arm_watch
    with_fake_github(FakeGithub.new(runs: [ completed_run(conclusion: "failure") ])) do
      RepositoryWatchReconcileJob.perform_now(watch.id)
    end
    assert_equal [ "fulfilled", "reconcile", "failure" ], [ watch.reload.state, watch.fulfilment["source"], watch.fulfilment["conclusion"] ]
  end

  test "reconcile: nothing finished yet, armed and done" do
    watch = arm_watch
    with_fake_github(FakeGithub.new(runs: [ completed_run.merge("status" => "in_progress") ])) do
      RepositoryWatchReconcileJob.perform_now(watch.id)
    end
    assert_equal [ "armed", "done" ], [ watch.reload.state, watch.reconcile_status ]
  end

  test "reconcile: GitHub unreachable means status not established, and a later delivery still fulfils" do
    watch = arm_watch
    with_fake_github(FakeGithub.new(error: RepositoryWatches::GithubClient::Error.new("GitHub answered 502", status: 502))) do
      RepositoryWatchReconcileJob.perform_now(watch.id)
    end
    watch.reload
    assert_equal [ "armed", "error", "status not established" ], [ watch.state, watch.reconcile_status, watch.status_label ]

    delivery = @repository.repository_deliveries.create!(delivery_guid: "late", event: "workflow_run", action: "completed",
                                                         received_at: Time.current, signature_ok: true, payload: { "workflow_run" => completed_run })
    RepositoryDeliveryJob.perform_now(delivery.id)
    assert_equal "fulfilled", watch.reload.state
  end

  test "reconcile: deployment already finished" do
    watch = arm_watch(event_kind: "deployment_status", filter: { "environment" => "production", "head_sha" => SHA }, wake: false)
    github = FakeGithub.new(deployments: [ { "id" => 5, "sha" => SHA, "environment" => "production" } ],
                            statuses: { 5 => [ { "id" => 11, "state" => "error", "target_url" => "https://example.com/d/5" } ] })
    with_fake_github(github) { RepositoryWatchReconcileJob.perform_now(watch.id) }
    assert_equal [ "fulfilled", "error", "reconcile" ], [ watch.reload.state, watch.fulfilment["state"], watch.fulfilment["source"] ]
  end

  # --- sweep ----------------------------------------------------------------

  test "sweep expires an overdue watch and posts one line, without waking" do
    watch = arm_watch
    travel 25.hours do
      perform_enqueued_jobs(only: RepositoryWatchDeliverJob) { RepositoryWatchSweepJob.perform_now }
      perform_enqueued_jobs(only: RepositoryWatchDeliverJob) { RepositoryWatchSweepJob.perform_now }
    end
    assert_equal "expired", watch.reload.state
    lines = @chat.messages.where(role: "system").where("content LIKE ?", "%expired%")
    assert_equal [ "swombat/other-repo · No completion was seen for `a1b2c3d` (CI) in 24 h; the watch has expired." ], lines.pluck(:content)
    assert_equal 0, PendingWakeSource.count
  end

  test "sweep retries reconcile for watches whose status was not established" do
    watch = arm_watch
    watch.update_columns(reconcile_status: "error", updated_at: 10.minutes.ago)
    assert_enqueued_with(job: RepositoryWatchReconcileJob, args: [ watch.id ]) { RepositoryWatchSweepJob.perform_now }
  end

end

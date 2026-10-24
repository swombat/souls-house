require "test_helper"
require "webmock/minitest"
require "support/repository_watch_helpers"

# Mira's review of #281: whatever is scheduled "after commit" can be lost in a
# crash or a failed enqueue, and durable state must bring it back. Each test
# loses one enqueue on purpose and shows the sweep (or a redelivery)
# recovering it, without doing anything twice.
class RepositoryWatchRecoveryTest < ActiveSupport::TestCase

  include RepositoryWatchHelpers
  include ActiveJob::TestHelper

  setup do
    build_watch_world
    @account.update!(use_system_ai_credentials: false, openrouter_api_key: "test-only-router")
  end

  def house_lines
    @chat.messages.where(role: "system").where("content LIKE ?", "swombat/other-repo%")
  end

  def receipt(guid: "guid-1", run: completed_run, **attributes)
    @repository.repository_deliveries.create!(
      delivery_guid: guid, event: "workflow_run", action: "completed", received_at: Time.current,
      signature_ok: true, payload: { "workflow_run" => run }, **attributes
    )
  end

  # --- receipts --------------------------------------------------------------

  test "a receipt whose job was lost is replayed by the sweep, and the watch fulfils once" do
    watch = arm_watch(wake: false)
    lost = receipt
    lost.update_columns(updated_at: 3.minutes.ago)

    assert_enqueued_with(job: RepositoryDeliveryJob, args: [ lost.id ]) { RepositoryWatchSweepJob.perform_now }
    perform_enqueued_jobs(only: [ RepositoryDeliveryJob, RepositoryWatchDeliverJob ]) { RepositoryWatchSweepJob.perform_now }

    assert lost.reload.processed_at
    assert_equal "fulfilled", watch.reload.state
    assert_equal 1, house_lines.count
  end

  test "a processed receipt is not replayed, and a fresh one waits out the grace period" do
    receipt(guid: "done", processed_at: 1.hour.ago).update_columns(updated_at: 1.hour.ago)
    receipt(guid: "fresh")
    assert_no_enqueued_jobs(only: RepositoryDeliveryJob) { RepositoryWatchSweepJob.perform_now }
  end

  test "a receipt that keeps failing stops being replayed and keeps its error" do
    stuck = receipt
    stuck.update_columns(process_attempts: RepositoryDelivery::MAX_PROCESS_ATTEMPTS, last_error: "boom", updated_at: 1.hour.ago)
    assert_no_enqueued_jobs(only: RepositoryDeliveryJob) { RepositoryWatchSweepJob.perform_now }
    assert_equal "boom", stuck.reload.last_error
  end

  test "a failing receipt records its attempt and error" do
    lost = receipt
    RepositoryWatch.stub(:workflow_fulfilment, ->(*, **) { raise ActiveRecord::Deadlocked, "transient" }) do
      arm_watch(wake: false)
      assert_raises(ActiveRecord::Deadlocked) { RepositoryDeliveryJob.new.perform(lost.id) }
    end
    assert_equal [ 1, nil ], [ lost.reload.process_attempts, lost.processed_at ]
    assert_match(/transient/, lost.last_error)
  end

  # --- watches ---------------------------------------------------------------

  test "a watch whose first reconcile was lost is reconciled by the sweep" do
    watch = arm_watch
    watch.update_columns(updated_at: 3.minutes.ago)
    assert_enqueued_with(job: RepositoryWatchReconcileJob, args: [ watch.id ]) { RepositoryWatchSweepJob.perform_now }

    with_fake_github(FakeGithub.new(runs: [ completed_run ])) do
      perform_enqueued_jobs(only: RepositoryWatchReconcileJob) { RepositoryWatchSweepJob.perform_now }
    end
    assert_equal [ "fulfilled", "reconcile" ], [ watch.reload.state, watch.fulfilment["source"] ]
  end

  test "a fulfilled watch whose delivery enqueue was lost is delivered by the sweep, once" do
    AgentRuntimeInteraction.reserve!(agent: @resident, chat: @chat)
    watch = arm_watch
    watch.fulfil!(RepositoryWatch.workflow_fulfilment(completed_run, source: "webhook"))
    clear_enqueued_jobs
    watch.repository_watch_deliveries.update_all(updated_at: 3.minutes.ago)

    perform_enqueued_jobs(only: RepositoryWatchDeliverJob) { RepositoryWatchSweepJob.perform_now }
    assert_equal 1, house_lines.count
    assert_equal 1, PendingWakeSource.count
    assert watch.repository_watch_deliveries.sole.completed?

    travel 2.hours do
      assert_no_enqueued_jobs(only: RepositoryWatchDeliverJob) { RepositoryWatchSweepJob.perform_now }
    end
  end

  test "an expired watch whose line was never posted is posted by the sweep" do
    watch = arm_watch
    travel 25.hours do
      RepositoryWatchSweepJob.perform_now
      clear_enqueued_jobs
      watch.repository_watch_deliveries.update_all(updated_at: 3.minutes.ago)
      perform_enqueued_jobs(only: RepositoryWatchDeliverJob) { RepositoryWatchSweepJob.perform_now }
    end
    assert_equal "expired", watch.reload.state
    assert_equal 1, @chat.messages.where(role: "system").where("content LIKE ?", "%has expired%").count
  end

  test "delivery retries back off, then end as a visible failure" do
    watch = arm_watch(wake: false)
    watch.fulfil!(RepositoryWatch.workflow_fulfilment(completed_run, source: "webhook"))
    delivery = watch.repository_watch_deliveries.sole

    delivery.update_columns(attempts: 3, updated_at: 5.minutes.ago)
    refute delivery.reload.retry_due?, "after 3 attempts the next try waits 8 minutes"
    delivery.update_columns(updated_at: 9.minutes.ago)
    assert delivery.reload.retry_due?

    delivery.update_columns(attempts: RepositoryWatchDelivery::MAX_ATTEMPTS, last_error: "Deadlocked", updated_at: 2.hours.ago)
    assert_no_enqueued_jobs(only: RepositoryWatchDeliverJob) { RepositoryWatchSweepJob.perform_now }
    RepositoryWatchDeliverJob.perform_now(watch.id)
    assert_equal 0, house_lines.count
    json = watch.reload.as_watch_json
    assert_equal "delivery failed", json[:status]
    assert_equal({ status: "failed", attempts: RepositoryWatchDelivery::MAX_ATTEMPTS, last_error: "Deadlocked" }, json[:delivery])
  end

  # --- pagination (the real client against stubbed GitHub) -----------------

  def runs_page(runs)
    { status: 200, headers: { "Content-Type" => "application/json" }, body: { total_count: 150, workflow_runs: runs }.to_json }
  end

  def runs_url
    "https://api.github.com/repos/swombat/other-repo/actions/runs"
  end

  test "reconcile finds a matching run on page two" do
    watch = arm_watch
    filler = Array.new(100) { |index| completed_run(name: "Lint", id: 1000 + index) }
    stub_request(:get, runs_url).with(query: hash_including("page" => "1")).to_return(runs_page(filler))
    stub_request(:get, runs_url).with(query: hash_including("page" => "2")).to_return(runs_page([ completed_run(conclusion: "failure") ]))

    RepositoryWatchReconcileJob.perform_now(watch.id)
    assert_equal [ "fulfilled", "failure" ], [ watch.reload.state, watch.fulfilment["conclusion"] ]
  end

  test "past the page bound, reconcile says status not established rather than 'none'" do
    watch = arm_watch
    filler = Array.new(100) { |index| completed_run(name: "Lint", id: index) }
    stub_request(:get, runs_url).with(query: hash_including({})).to_return(runs_page(filler))

    RepositoryWatchReconcileJob.perform_now(watch.id)
    assert_equal [ "armed", "error", "status not established" ], [ watch.reload.state, watch.reconcile_status, watch.status_label ]
    assert_match(/not all could be searched/, watch.reconcile_error)
  end

  test "reconcile finds a deployment of the sha on page two" do
    watch = arm_watch(event_kind: "deployment_status", filter: { "head_sha" => SHA }, wake: false)
    url = "https://api.github.com/repos/swombat/other-repo/deployments"
    json = { "Content-Type" => "application/json" }
    filler = Array.new(100) { |index| { id: index, sha: SHA, environment: "staging", created_at: "2026-10-10T10:00:00Z" } }
    stub_request(:get, url).with(query: hash_including("page" => "1")).to_return(status: 200, headers: json, body: filler.to_json)
    stub_request(:get, url).with(query: hash_including("page" => "2"))
      .to_return(status: 200, headers: json, body: [ { id: 500, sha: SHA, environment: "production", created_at: "2026-10-09T10:00:00Z" } ].to_json)
    stub_request(:get, %r{/deployments/\d+/statuses}).to_return(status: 200, headers: json, body: [].to_json)
    stub_request(:get, "#{url}/500/statuses").with(query: hash_including({}))
      .to_return(status: 200, headers: json, body: [ { id: 9, state: "success", environment: "production", created_at: "2026-10-09T10:05:00Z" } ].to_json)

    RepositoryWatchReconcileJob.perform_now(watch.id)
    assert_equal [ "fulfilled", "production", "success" ], [ watch.reload.state, watch.fulfilment["environment"], watch.fulfilment["state"] ]
  end

  # --- environment-only deployment watches ----------------------------------

  test "an environment-only watch is not fulfilled by a deploy that finished before it was armed" do
    watch = arm_watch(event_kind: "deployment_status", filter: { "environment" => "production" }, wake: false)
    before = (watch.created_at - 10.minutes).iso8601
    github = FakeGithub.new(deployments: [ { "id" => 5, "sha" => SHA, "environment" => "production", "created_at" => (watch.created_at - 20.minutes).iso8601 } ],
                            statuses: { 5 => [ { "id" => 1, "state" => "success", "created_at" => before } ] })
    with_fake_github(github) { RepositoryWatchReconcileJob.perform_now(watch.id) }
    assert_equal [ "armed", "done" ], [ watch.reload.state, watch.reconcile_status ]
  end

  test "an environment-only watch is fulfilled by a deploy that finished after it was armed" do
    watch = arm_watch(event_kind: "deployment_status", filter: { "environment" => "production" }, wake: false)
    github = FakeGithub.new(deployments: [ { "id" => 5, "sha" => SHA, "environment" => "production", "created_at" => (watch.created_at - 5.minutes).iso8601 } ],
                            statuses: { 5 => [ { "id" => 1, "state" => "failure", "created_at" => (watch.created_at + 1.second).iso8601 } ] })
    with_fake_github(github) { RepositoryWatchReconcileJob.perform_now(watch.id) }
    assert_equal [ "fulfilled", "failure" ], [ watch.reload.state, watch.fulfilment["state"] ]
  end


  # --- second review: fair recovery and one temporal rule ------------------

  def with_sweep_batch(size)
    original = RepositoryWatchSweepJob::BATCH
    silence_warnings { RepositoryWatchSweepJob.const_set(:BATCH, size) }
    yield
  ensure
    silence_warnings { RepositoryWatchSweepJob.const_set(:BATCH, original) }
  end

  def fulfilled_delivery(attempts:, updated_at:)
    watch = arm_watch(wake: false)
    watch.fulfil!(RepositoryWatch.workflow_fulfilment(completed_run, source: "webhook"))
    watch.repository_watch_deliveries.sole.tap { |delivery| delivery.update_columns(attempts: attempts, updated_at: updated_at) }
  end

  test "failed and backing-off deliveries never fill the sweep batch ahead of a due one" do
    3.times { fulfilled_delivery(attempts: RepositoryWatchDelivery::MAX_ATTEMPTS, updated_at: 3.hours.ago) }
    2.times { fulfilled_delivery(attempts: 5, updated_at: 10.minutes.ago) }
    due = fulfilled_delivery(attempts: 1, updated_at: 3.minutes.ago)
    clear_enqueued_jobs

    with_sweep_batch(2) do
      RepositoryWatchSweepJob.perform_now
    end
    assert_equal [ [ due.repository_watch_id ] ], enqueued_jobs.select { |job| job["job_class"] == "RepositoryWatchDeliverJob" }.map { |job| job["arguments"] }
  end

  test "the SQL due rule agrees with retry_due? across the backoff" do
    delivery = fulfilled_delivery(attempts: 0, updated_at: Time.current)
    now = Time.current
    [ 0, 1, 3, 6, 10, 11, RepositoryWatchDelivery::MAX_ATTEMPTS ].product([ 1, 3, 9, 33, 61, 200 ]).each do |attempts, minutes|
      delivery.update_columns(attempts: attempts, updated_at: now - minutes.minutes)
      expected = delivery.reload.retry_due?(now)
      assert_equal expected, RepositoryWatchDelivery.retry_due(now).exists?(delivery.id), "attempts=#{attempts} minutes=#{minutes}"
    end
  end

  def deployment_receipt(status_created_at:, sha: OTHER_SHA, guid: SecureRandom.uuid)
    payload = {
      "repository" => { "full_name" => "swombat/other-repo" },
      "deployment_status" => { "id" => 31, "state" => "success", "environment" => "production", "created_at" => status_created_at },
      "deployment" => { "id" => 30, "sha" => sha, "environment" => "production" }
    }
    @repository.repository_deliveries.create!(
      delivery_guid: guid, event: "deployment_status", action: "created", received_at: Time.current,
      signature_ok: true, payload: RepositoryDelivery.reduce_payload("deployment_status", payload)
    )
  end

  test "a delayed webhook for a deploy that finished before arming does not fulfil a next-deploy watch" do
    watch = arm_watch(event_kind: "deployment_status", filter: { "environment" => "production" }, wake: false)
    RepositoryDeliveryJob.perform_now(deployment_receipt(status_created_at: (watch.created_at - 10.minutes).iso8601).id)
    assert_equal "armed", watch.reload.state

    RepositoryDeliveryJob.perform_now(deployment_receipt(status_created_at: (watch.created_at + 1.minute).iso8601).id)
    assert_equal [ "fulfilled", "webhook" ], [ watch.reload.state, watch.fulfilment["source"] ]
  end

  test "a webhook status with no time does not fulfil a next-deploy watch" do
    watch = arm_watch(event_kind: "deployment_status", filter: { "environment" => "production" }, wake: false)
    RepositoryDeliveryJob.perform_now(deployment_receipt(status_created_at: nil).id)
    assert_equal "armed", watch.reload.state
  end

  test "an exact-sha deployment watch still accepts a status from before arming" do
    watch = arm_watch(event_kind: "deployment_status", filter: { "head_sha" => OTHER_SHA, "environment" => "production" }, wake: false)
    RepositoryDeliveryJob.perform_now(deployment_receipt(status_created_at: (watch.created_at - 2.days).iso8601).id)
    assert_equal "fulfilled", watch.reload.state
  end

  def deployments_url
    "https://api.github.com/repos/swombat/other-repo/deployments"
  end

  def json_reply(body)
    { status: 200, headers: { "Content-Type" => "application/json" }, body: body.to_json }
  end

  test "reconcile counts a deploy started long before arming that finished after it (real client)" do
    watch = arm_watch(event_kind: "deployment_status", filter: { "environment" => "production" }, wake: false)
    finished = (watch.created_at + 30.seconds).iso8601
    stub_request(:get, deployments_url).with(query: hash_including("environment" => "production")).to_return(json_reply([
      { id: 41, sha: SHA, environment: "production", created_at: (watch.created_at - 1.minute).iso8601, updated_at: (watch.created_at - 1.minute).iso8601 },
      { id: 40, sha: SHA, environment: "production", created_at: (watch.created_at - 2.hours).iso8601, updated_at: finished }
    ]))
    stub_request(:get, "#{deployments_url}/40/statuses").with(query: hash_including({}))
      .to_return(json_reply([ { id: 9, state: "success", environment: "production", created_at: finished } ]))

    RepositoryWatchReconcileJob.perform_now(watch.id)
    assert_equal [ "fulfilled", 40, "reconcile" ], [ watch.reload.state, watch.fulfilment["deployment_id"], watch.fulfilment["source"] ]
    assert_not_requested :get, %r{/deployments/41/statuses}
  end

  test "reconcile of a next-deploy watch past the listing bound is not established, not absent (real client)" do
    watch = arm_watch(event_kind: "deployment_status", filter: { "environment" => "production" }, wake: false)
    old = (watch.created_at - 3.days).iso8601
    page = Array.new(RepositoryWatches::GithubClient::PER_PAGE) { |index| { id: index, sha: SHA, environment: "production", created_at: old, updated_at: old } }
    stub_request(:get, deployments_url).with(query: hash_including({})).to_return(json_reply(page))

    RepositoryWatchReconcileJob.perform_now(watch.id)
    assert_equal [ "armed", "error" ], [ watch.reload.state, watch.reconcile_status ]
    assert_not_requested :get, %r{/deployments/\d+/statuses}
  end

end

require "test_helper"
require "support/repository_watch_helpers"

class RepositoryWatchTest < ActiveSupport::TestCase

  include RepositoryWatchHelpers
  include ActiveJob::TestHelper

  setup { build_watch_world }

  # --- arming -------------------------------------------------------------

  test "a resident with a grant arms a watch: persisted armed, pending reconcile, enqueued after commit" do
    watch = nil
    assert_enqueued_with(job: RepositoryWatchReconcileJob) { watch = arm_watch }
    assert_equal [ "armed", "pending", [ @resident.id ] ], [ watch.state, watch.reconcile_status, watch.wake_agent_ids ]
    assert_in_delta 24.hours.from_now, watch.expires_at, 5
  end

  test "no grant, no watch" do
    @resident.agent_service_accesses.update_all(enabled: false)
    error = assert_raises(RepositoryWatch::Refused) { arm_watch }
    assert_equal :forbidden, error.status
  end

  test "a resident not in the room cannot arm a watch for it" do
    bystander = @account.agents.create!(name: "Bystander", system_prompt: "Test", runtime: "external")
    other = @account.chats.new(title: "Elsewhere", manual_responses: true)
    other.agents = [ bystander ]
    other.save!
    error = assert_raises(RepositoryWatch::Refused) { arm_watch(chat: other) }
    assert_equal :forbidden, error.status
  end

  test "a room with a guest resident from another account is refused at arm (readership)" do
    guest = accounts(:team_account).agents.create!(name: "Guest", system_prompt: "Test", runtime: "external")
    @account.guest_memberships.create!(agent: guest, added_by: @user)
    @chat.agents << guest
    error = assert_raises(RepositoryWatch::Refused) { arm_watch }
    assert_equal :unprocessable_entity, error.status
    assert_match(/guest resident/, error.message)
  end

  test "a person cannot ask to be woken; only the arming resident can be" do
    assert_raises(RepositoryWatch::Refused) { arm_watch(by: @user, wake: true) }
    watch = arm_watch(by: @user, wake: false)
    assert_equal [], watch.wake_agent_ids
    assert_equal @user, watch.created_by_user
  end

  test "filters are validated" do
    assert_raises(RepositoryWatch::Refused) { arm_watch(filter: { "workflow_name" => "CI" }) }
    assert_raises(RepositoryWatch::Refused) { arm_watch(filter: { "head_sha" => "xyz" }) }
    assert_raises(RepositoryWatch::Refused) { arm_watch(filter: { "head_sha" => SHA, "conclusions" => "maybe" }) }
    assert_raises(RepositoryWatch::Refused) { arm_watch(event_kind: "deployment_status", filter: {}) }
    assert_raises(RepositoryWatch::Refused) { arm_watch(event_kind: "deployment_status", filter: { "environment" => "production", "states" => "pending" }) }
    assert_raises(RepositoryWatch::Refused) { arm_watch(event_kind: "push") }
    assert_raises(RepositoryWatch::Refused) { arm_watch(expires_in: "8d") }
    assert_raises(RepositoryWatch::Refused) { arm_watch(expires_in: "soon") }
  end

  test "a short sha is accepted only if GitHub resolves it to one full sha" do
    watch = arm_watch(filter: { "head_sha" => SHA.first(7) }, github: FakeGithub.new(commit: SHA))
    assert_equal SHA, watch.head_sha

    assert_raises(RepositoryWatch::Refused) do
      arm_watch(filter: { "head_sha" => SHA.first(7) }, github: FakeGithub.new(commit: OTHER_SHA))
    end
    assert_raises(RepositoryWatch::Refused) do
      arm_watch(filter: { "head_sha" => SHA.first(7) }, github: FakeGithub.new(error: RepositoryWatches::GithubClient::Error.new("Not Found", status: 404)))
    end
  end

  # --- matching -----------------------------------------------------------

  test "workflow matching: sha, name, conclusions, completed only" do
    watch = arm_watch(filter: { "head_sha" => SHA, "workflow_name" => "CI", "conclusions" => %w[failure] })
    assert watch.matches_workflow_run?(completed_run(conclusion: "failure"))
    refute watch.matches_workflow_run?(completed_run(conclusion: "success"))
    refute watch.matches_workflow_run?(completed_run(conclusion: "failure", name: "Lint"))
    refute watch.matches_workflow_run?(completed_run(conclusion: "failure", sha: OTHER_SHA))
    refute watch.matches_workflow_run?(completed_run(conclusion: "failure").merge("status" => "in_progress"))
  end

  test "deployment matching: terminal states only, environment and sha" do
    watch = arm_watch(event_kind: "deployment_status", filter: { "environment" => "production", "head_sha" => SHA })
    deployment = { "id" => 5, "sha" => SHA, "environment" => "production" }
    assert watch.matches_deployment_status?({ "state" => "success" }, deployment)
    assert watch.matches_deployment_status?({ "state" => "failure", "environment" => "production" }, deployment)
    refute watch.matches_deployment_status?({ "state" => "in_progress" }, deployment)
    refute watch.matches_deployment_status?({ "state" => "success" }, deployment.merge("environment" => "staging"))
    refute watch.matches_deployment_status?({ "state" => "success" }, deployment.merge("sha" => OTHER_SHA))
  end

  # --- fulfilment ---------------------------------------------------------

  test "fulfil is the one idempotent path: a second fulfilment changes nothing" do
    watch = arm_watch
    assert watch.fulfil!(RepositoryWatch.workflow_fulfilment(completed_run, source: "webhook"))
    refute watch.reload.fulfil!(RepositoryWatch.workflow_fulfilment(completed_run(conclusion: "failure"), source: "reconcile"))
    assert_equal [ "fulfilled", "success", "webhook" ], [ watch.reload.state, watch.fulfilment["conclusion"], watch.fulfilment["source"] ]
    assert_equal 1, watch.repository_watch_deliveries.count
  end

  test "two concurrent fulfilments: exactly one wins" do
    watch = arm_watch
    results = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          RepositoryWatch.find(watch.id).fulfil!(RepositoryWatch.workflow_fulfilment(completed_run, source: "webhook"))
        end
      end
    end.map(&:value)
    assert_equal [ false, true ], results.sort_by { |result| result ? 1 : 0 }
    assert_equal 1, watch.repository_watch_deliveries.count
  end

  test "a cancelled watch is not fulfilled" do
    watch = arm_watch
    watch.cancel!(reason: "no longer needed")
    refute watch.reload.fulfil!(RepositoryWatch.workflow_fulfilment(completed_run, source: "webhook"))
    assert_equal "cancelled", watch.reload.state
  end

  test "the delivered line is the fact, with the run url" do
    watch = arm_watch
    watch.fulfil!(RepositoryWatch.workflow_fulfilment(completed_run(conclusion: "timed_out"), source: "webhook"))
    assert_equal "swombat/other-repo · CI finished for a1b2c3d: timed_out · https://github.com/swombat/other-repo/actions/runs/777",
                 watch.reload.delivered_text
  end

  test "a non-http url from the payload is dropped from the line" do
    watch = arm_watch
    watch.fulfil!(RepositoryWatch.workflow_fulfilment(completed_run.merge("html_url" => "javascript:alert(1)"), source: "webhook"))
    assert_equal "swombat/other-repo · CI finished for a1b2c3d: success", watch.reload.delivered_text
  end

  test "status reads 'status not established' while reconcile errored" do
    watch = arm_watch
    watch.update_columns(reconcile_status: "error", reconcile_error: "GitHub 502")
    assert_equal "status not established", watch.as_watch_json[:status]
  end

  test "with no public URL the hook is not installed and the repository says why" do
    Rails.configuration.x.public_url = nil
    github = FakeGithub.new
    repository = with_fake_github(github) { WatchedRepository.connect!(connection: @connection, full_name: "swombat/third", user: @user) }
    assert_equal "failed", repository.hook_status
    assert_match(/no public URL/, repository.hook_error)
    refute github.calls.any? { |call| call.first == :create_hook }
    assert_nil repository.as_repository_json(include_setup: true).dig(:setup, :url)
  end

  test "the receiver URL is the house's public URL and the repository's token" do
    assert_equal "https://house.example.test/webhooks/repositories/#{@repository.receiver_token}", @repository.receiver_url
  end

  # --- removal ------------------------------------------------------------

  test "disconnecting the repository cancels armed watches with the reason" do
    watch = arm_watch
    with_fake_github { @repository.remove!(reason: "repository disconnected") }
    assert_equal [ "cancelled", "repository disconnected" ], [ watch.reload.state, watch.cancel_reason ]
  end

  test "a revoked GitHub connection removes its repositories and cancels their watches" do
    watch = arm_watch
    @connection.update!(status: "revoked")
    assert @repository.reload.removed?
    assert_equal "cancelled", watch.reload.state
  end

end

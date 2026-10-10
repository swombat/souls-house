require "test_helper"

# Every GitHub answer here comes through DeployInfo.fetcher and
# HouseDeploy.transport; nothing touches the network or Honeybadger.
class DeployAlarmTest < ActiveSupport::TestCase

  REPO = "/repos/swombat/souls-house"
  DEPLOYED = "fcb643c" + "0" * 33
  MASTER_A = "7257c15" + "1" * 33
  MASTER_B = "1e35e62" + "2" * 33
  CAUGHT_UP = "7a2604f" + "3" * 33
  T0 = Time.utc(2026, 10, 9, 22, 12)

  setup do
    @notices = []
    @fetches = {}
    @manual_runs = []
    @auto_runs = []
    @jobs = {}
    @kamal_version = ENV["KAMAL_VERSION"]
    @booted_at = Rails.application.config.x.booted_at
    @fetcher = DeployInfo.fetcher
    @transport = HouseDeploy.transport
    @token_source = HouseDeploy.token_source

    Rails.application.config.x.booted_at = T0 - 3.hours
    fetches = @fetches
    DeployInfo.fetcher = ->(path) { fetches.fetch(path) { nil } }
    HouseDeploy.token_source = -> { "test-token" }
    @github_down = false
    HouseDeploy.transport = lambda { |_method, path, _body|
      next [ 503, {}, nil ] if @github_down

      case path
      when %r{/actions/runs\?event=workflow_dispatch} then [ 200, {}, { "workflow_runs" => @manual_runs } ]
      when %r{/workflows/deploy-rails-on-green\.yml/runs} then [ 200, {}, { "workflow_runs" => @auto_runs } ]
      when %r{/actions/runs/(\d+)/attempts/\d+/jobs} then [ 200, {}, @jobs.fetch(Regexp.last_match(1).to_i, { "jobs" => [] }) ]
      else [ 404, {}, nil ]
      end
    }
    production(DEPLOYED, master: MASTER_A, behind: 1)
  end

  teardown do
    ENV["KAMAL_VERSION"] = @kamal_version
    Rails.application.config.x.booted_at = @booted_at
    DeployInfo.fetcher = @fetcher
    HouseDeploy.transport = @transport
    HouseDeploy.token_source = @token_source
  end

  test "behind with an automatic deploy in progress is ok" do
    production(DEPLOYED, master: MASTER_B, behind: 2)
    @auto_runs = [ auto_run(1, MASTER_B, status: "in_progress", conclusion: nil) ]

    assert_equal "ok", check(T0).state
    assert_equal "ok", check(T0 + 40.minutes).state
    assert_empty @notices
  end

  test "behind with a manual deploy queued is ok" do
    production(DEPLOYED, master: MASTER_B, behind: 2)
    @manual_runs = [ manual_run(9, status: "queued") ]

    assert_equal "ok", check(T0).state
    assert_equal "ok", check(T0 + 2.hours).state
  end

  test "an automatic run in progress outranks an older failure" do
    production(DEPLOYED, master: MASTER_B, behind: 2)
    @auto_runs = [ auto_run(2, MASTER_B, status: "in_progress", conclusion: nil), auto_run(1, MASTER_A, conclusion: "failure") ]

    assert_equal "ok", check(T0).state
    assert_empty @notices
  end

  test "newest automatic run superseded is ok" do
    @auto_runs = [ auto_run(1, MASTER_A, conclusion: "success") ]
    @jobs[1] = { "jobs" => [ { "steps" => [ { "name" => HouseDeploy::SUPERSEDED_STEP, "conclusion" => "success" } ] } ] }

    assert_equal "ok", check(T0).state
    assert_empty @notices
  end

  test "a cancelled automatic run is not a failure" do
    @auto_runs = [ auto_run(1, MASTER_A, conclusion: "cancelled") ]

    assert_equal "ok", check(T0).state
  end

  test "newest automatic run failed for a commit that isn't running: stuck at once, one notice" do
    @auto_runs = [ auto_run(1, MASTER_A, conclusion: "failure") ]

    state = check(T0)

    assert_equal "stuck", state.state
    assert_equal 1, @notices.size
    error, options = @notices.first
    assert_kind_of DeployAlarm::ProductionBehindMaster, error
    assert_equal "deploy-alarm-#{MASTER_A}", options[:fingerprint]
    assert_equal DEPLOYED, options[:context][:deployed_sha]
    assert_equal MASTER_A, options[:context][:master_sha]
  end

  test "a successful Rails deploy after the failure makes it old news" do
    production(DEPLOYED, master: MASTER_B, behind: 2)
    @auto_runs = [ auto_run(1, MASTER_A, conclusion: "failure") ]
    @manual_runs = [ manual_run(9, status: "completed", conclusion: "success", at: T0) ]

    assert_equal "ok", check(T0 + 2.minutes).state
    assert_empty @notices
  end

  test "a process restart on the same image doesn't make a failure old news" do
    Rails.application.config.x.booted_at = T0 + 1.minute
    @auto_runs = [ auto_run(1, MASTER_A, conclusion: "failure") ]

    assert_equal "stuck", check(T0 + 2.minutes).state
    assert_equal 1, @notices.size
  end

  test "a run for another commit doesn't clear a stuck alarm or re-notify when it ends" do
    @auto_runs = [ auto_run(1, MASTER_A, conclusion: "failure") ]
    check(T0)
    old_runtime = manual_run(9, status: "in_progress", sha: DEPLOYED, path: "deploy-runtime.yml")
    @manual_runs = [ old_runtime ]

    state = check(T0 + 5.minutes)
    assert_equal "stuck", state.state
    assert_equal T0, state.since

    @manual_runs = [ old_runtime.merge("status" => "completed", "conclusion" => "success") ]
    check(T0 + 10.minutes)
    assert_equal 1, @notices.size
  end

  test "with master unknown, an active run doesn't count as a deploy in flight" do
    @auto_runs = [ auto_run(1, MASTER_A, conclusion: "failure") ]
    @manual_runs = [ manual_run(9, status: "in_progress") ]
    @fetches.clear

    assert_equal "stuck", check(T0).state
  end

  test "a runtime deploy of master in flight counts" do
    @auto_runs = [ auto_run(1, MASTER_A, conclusion: "failure") ]
    @manual_runs = [ manual_run(9, status: "in_progress", sha: MASTER_A, path: "deploy-runtime.yml") ]

    assert_equal "ok", check(T0).state
  end

  test "a notice Honeybadger refused is retried on the next check, then not repeated" do
    @auto_runs = [ auto_run(1, MASTER_A, conclusion: "failure") ]
    attempts = 0
    Honeybadger.stub(:notify, ->(*) { attempts += 1; raise "honeybadger down" }) { DeployAlarm.check!(now: T0) }

    state = DeployAlarmState.current
    assert_equal "stuck", state.state
    assert_nil state.notified_at
    assert_equal 1, attempts

    check(T0 + 5.minutes)
    check(T0 + 10.minutes)
    assert_equal 1, @notices.size
    assert_equal T0, DeployAlarmState.current.since
  end

  test "behind for 29 minutes with no run is ok; at 31 it is stuck, once" do
    assert_equal "ok", check(T0).state
    assert_equal "ok", check(T0 + 29.minutes).state
    assert_empty @notices

    state = check(T0 + 31.minutes)
    assert_equal "stuck", state.state
    assert_equal T0, state.since
    assert_equal 1, @notices.size
    assert_equal "No deploy has run since master moved ahead.", @notices.first.last[:context][:reason]
  end

  test "six consecutive stuck checks make one notice" do
    @auto_runs = [ auto_run(1, MASTER_A, conclusion: "failure") ]

    6.times { |i| check(T0 + (i * 5).minutes) }

    assert_equal "stuck", DeployAlarmState.current.state
    assert_equal 1, @notices.size
    assert_equal T0, DeployAlarmState.current.since
  end

  test "master moving on while stuck makes a second notice with the new fingerprint" do
    @auto_runs = [ auto_run(1, MASTER_A, conclusion: "failure") ]
    check(T0)
    production(DEPLOYED, master: MASTER_B, behind: 3)
    check(T0 + 5.minutes)
    check(T0 + 10.minutes)

    assert_equal [ "deploy-alarm-#{MASTER_A}", "deploy-alarm-#{MASTER_B}" ], @notices.map { |_, o| o[:fingerprint] }
  end

  test "catching up clears the alarm without a notice" do
    @auto_runs = [ auto_run(1, MASTER_A, conclusion: "failure") ]
    check(T0)
    production(CAUGHT_UP, master: CAUGHT_UP, behind: 0)

    state = check(T0 + 40.minutes)

    assert_equal "ok", state.state
    assert_nil state.since
    assert_nil state.reason
    assert_nil state.notified_at
    assert_nil state.behind_since
    assert_equal 1, @notices.size
  end

  test "GitHub unreachable is unknown, never a notice; after 30 minutes the banner says so" do
    @fetches.clear

    assert_equal "unknown", check(T0).state
    assert_equal "unknown", check(T0 + 35.minutes).state
    assert_empty @notices

    assert_not DeployAlarm.payload(now: T0 + 20.minutes).nil?
    travel_to(T0 + 35.minutes) do
      payload = DeployAlarm.payload
      assert_equal "unknown", payload[:state]
      assert payload[:banner]
      assert_equal T0.iso8601, payload[:since]
    end
  end

  test "unknown for under 30 minutes shows no banner" do
    @fetches.clear
    check(T0)
    travel_to(T0 + 10.minutes) { assert_not DeployAlarm.payload[:banner] }
  end

  test "a dirty build is unknown" do
    ENV["KAMAL_VERSION"] = "#{DEPLOYED}_uncommitted_abc"

    state = check(T0)

    assert_equal "unknown", state.state
    assert_equal "The running build has uncommitted changes.", state.reason
  end

  test "a GitHub blip during a stuck episode doesn't cause a second notice or move its start" do
    @auto_runs = [ auto_run(1, MASTER_A, conclusion: "failure") ]
    check(T0)
    saved = @fetches.dup
    @fetches.clear
    @github_down = true
    assert_equal "unknown", check(T0 + 5.minutes).state
    @fetches.merge!(saved)
    @github_down = false
    state = check(T0 + 10.minutes)

    assert_equal 1, @notices.size
    assert_equal "stuck", state.state
    assert_equal T0, state.since
  end

  test "a check that has gone quiet is reported, not read as fine" do
    production(DEPLOYED, master: DEPLOYED, behind: 0)
    check(T0)

    travel_to(T0 + 25.minutes) do
      payload = DeployAlarm.payload
      assert_equal "unknown", payload[:state]
      assert payload[:stale]
      assert payload[:banner]
    end
  end

  test "a failing check records its error and leaves last_checked_at alone" do
    check(T0)
    HouseDeploy.stub(:status, ->(**) { raise "boom" }) { DeployAlarm.check!(now: T0 + 5.minutes) }

    state = DeployAlarmState.current
    assert_equal T0, state.last_checked_at
    assert_match "boom", state.last_error
  end

  # Yesterday at 22:12Z: master 7257c15 then 1e35e62 ahead of fcb643c, and the
  # automatic run for 7257c15 failed with "Deployment request unavailable".
  test "acceptance: replay of 9 Oct 22:12Z" do
    @auto_runs = [ auto_run(37934442766, MASTER_A, conclusion: "failure") ]
    @jobs[37934442766] = { "jobs" => [ { "steps" => [
      { "name" => "Set up job", "conclusion" => "success" },
      { "name" => "Deploy", "conclusion" => "failure" }
    ] } ] }
    production(DEPLOYED, master: MASTER_A, behind: 1)

    state = check(T0)
    assert_equal "stuck", state.state
    assert_equal "Last automatic deploy (7257c15) failed at “Deploy”.", state.reason
    assert_equal "https://github.com/swombat/souls-house/actions/runs/37934442766", state.last_run_url

    production(DEPLOYED, master: MASTER_B, behind: 3)
    @auto_runs = [ auto_run(37934442766, MASTER_A, conclusion: "failure") ]
    check(T0 + 5.minutes)

    _, first = @notices.first
    assert_equal({ deployed_sha: DEPLOYED, master_sha: MASTER_A, behind_by: 1,
      reason: "Last automatic deploy (7257c15) failed at “Deploy”.",
      last_run_url: "https://github.com/swombat/souls-house/actions/runs/37934442766",
      since: T0.iso8601 }, first[:context])

    travel_to(T0 + 6.minutes) do
      payload = DeployAlarm.payload
      assert_equal "stuck", payload[:state]
      assert payload[:banner]
      assert_equal "fcb643c", payload[:deployed_short]
      assert_equal 3, payload[:behind_by]
      assert_equal T0.iso8601, payload[:since]
    end

    production(CAUGHT_UP, master: CAUGHT_UP, behind: 0)
    count = @notices.size
    assert_equal "ok", check(T0 + 50.minutes).state
    assert_equal count, @notices.size
  end

  private

  def check(now)
    Honeybadger.stub(:notify, ->(error, **options) { @notices << [ error, options ] }) do
      DeployAlarm.check!(now:)
    end
    DeployAlarmState.current
  end

  def production(deployed, master:, behind:)
    ENV["KAMAL_VERSION"] = deployed
    @fetches.clear
    @fetches["#{REPO}/commits/master"] = { "sha" => master, "commit" => { "committer" => { "date" => T0.iso8601 }, "message" => "m" } }
    @fetches["#{REPO}/compare/#{deployed}...#{master}"] = { "status" => "ahead", "ahead_by" => behind } if behind.to_i.positive?
  end

  def auto_run(id, tested, status: "completed", conclusion: "failure")
    {
      "id" => id, "run_attempt" => 1,
      "path" => ".github/workflows/deploy-rails-on-green.yml",
      "status" => status, "conclusion" => conclusion,
      "display_title" => "Deploy Rails #{tested}", "head_sha" => tested,
      "created_at" => (T0 - 5.minutes).iso8601, "updated_at" => (T0 - 1.minute).iso8601,
      "html_url" => "https://github.com/swombat/souls-house/actions/runs/#{id}"
    }
  end

  def manual_run(id, status:, conclusion: nil, sha: MASTER_B, path: "deploy-rails.yml", at: T0)
    {
      "id" => id, "run_attempt" => 1, "path" => ".github/workflows/#{path}",
      "status" => status, "conclusion" => conclusion, "head_sha" => sha,
      "created_at" => at.iso8601, "updated_at" => at.iso8601,
      "html_url" => "https://github.com/swombat/souls-house/actions/runs/#{id}"
    }
  end

end

require "test_helper"

class HouseDeployTest < ActiveSupport::TestCase

  setup do
    @calls = []
    @reply = [ 204, {}, nil ]
    calls = @calls
    test = self
    @original_transport = HouseDeploy.transport
    HouseDeploy.transport = ->(method, path, body) { calls << [ method, path, body ]; test.instance_variable_get(:@reply) }
    @original_token_source = HouseDeploy.token_source
    HouseDeploy.token_source = -> { "github_pat_test" }
  end

  teardown do
    HouseDeploy.transport = @original_transport
    HouseDeploy.token_source = @original_token_source
  end

  test "dispatch posts to the workflow pinned to master" do
    config = HouseDeploy.dispatch!("rails")

    assert_equal "Deploy Rails", config[:name]
    assert_equal [ [ :post, "/repos/swombat/souls-house/actions/workflows/deploy-rails.yml/dispatches", { ref: "master" } ] ], @calls
  end

  test "unknown workflow is refused without calling GitHub" do
    assert_raises(HouseDeploy::Error) { HouseDeploy.dispatch!("../ci") }
    assert_empty @calls
  end

  test "no token refuses without calling GitHub" do
    HouseDeploy.token_source = -> { nil }

    error = assert_raises(HouseDeploy::Error) { HouseDeploy.dispatch!("rails") }
    assert_match(/No deploy token/, error.message)
    assert_empty @calls
    assert_equal false, HouseDeploy.status[:configured]
  end

  test "GitHub refusal becomes a readable error" do
    @reply = [ 401, {}, { "message" => "Bad credentials" } ]

    error = assert_raises(HouseDeploy::Error) { HouseDeploy.dispatch!("both") }
    assert_match(/expired or revoked/, error.message)
  end

  test "status keeps only the deploy workflows and reads the token expiry" do
    @reply = [ 200, { "github-authentication-token-expiration" => "2027-10-08 10:00:00 UTC" }, {
      "workflow_runs" => [
        { "id" => 1, "path" => ".github/workflows/ci.yml", "status" => "completed" },
        { "id" => 2, "path" => ".github/workflows/deploy-rails.yml", "status" => "in_progress", "conclusion" => nil,
          "head_sha" => "abcdef1234", "triggering_actor" => { "login" => "swombat" }, "created_at" => "2026-10-08T06:00:00Z",
          "html_url" => "https://github.com/swombat/souls-house/actions/runs/2" }
      ]
    } ]

    status = HouseDeploy.status

    assert status[:configured]
    assert_nil status[:error]
    assert_equal [ 2 ], status[:runs].map { |run| run[:id] }
    run = status[:runs].first
    assert_equal "rails", run[:workflow]
    assert_equal "abcdef1", run[:head_sha]
    assert_equal "swombat", run[:actor]
    assert_equal "2027-10-08T10:00:00Z", status[:token_expires_at]
  end

  test "status reports GitHub failure instead of raising" do
    @reply = [ nil, {}, nil ]

    status = HouseDeploy.status

    assert_equal "GitHub unreachable", status[:error]
    assert_empty status[:runs]
  end

  test "status lists automatic Rails deploys beside manual ones, newest first, without skipped runs" do
    manual = { "workflow_runs" => [
      { "id" => 2, "path" => ".github/workflows/deploy-rails.yml", "status" => "completed", "conclusion" => "success",
        "head_sha" => "aaaaaaa111", "created_at" => "2026-10-08T06:00:00Z" }
    ] }
    automatic = { "workflow_runs" => [
      { "id" => 3, "path" => ".github/workflows/deploy-rails-on-green.yml", "status" => "in_progress", "conclusion" => nil,
        "head_sha" => "bbbbbbb222", "actor" => { "login" => "swombat" }, "created_at" => "2026-10-08T07:00:00Z" },
      { "id" => 4, "path" => ".github/workflows/deploy-rails-on-green.yml", "status" => "completed", "conclusion" => "skipped",
        "head_sha" => "ccccccc333", "created_at" => "2026-10-08T08:00:00Z" }
    ] }
    HouseDeploy.transport = ->(_method, path, _body) {
      path.include?("deploy-rails-on-green.yml/runs") ? [ 200, {}, automatic ] : [ 200, {}, manual ]
    }

    runs = HouseDeploy.status[:runs]

    assert_equal [ 3, 2 ], runs.map { |run| run[:id] }
    assert_equal [ "rails_auto", "rails" ], runs.map { |run| run[:workflow] }
    assert_match(/automatic/, runs.first[:name])
  end

  test "a failed automatic-run lookup still shows the manual runs" do
    manual = { "workflow_runs" => [
      { "id" => 2, "path" => ".github/workflows/deploy-rails.yml", "status" => "completed", "created_at" => "2026-10-08T06:00:00Z" }
    ] }
    HouseDeploy.transport = ->(_method, path, _body) {
      path.include?("deploy-rails-on-green.yml/runs") ? [ 404, {}, { "message" => "Not Found" } ] : [ 200, {}, manual ]
    }

    status = HouseDeploy.status

    assert_nil status[:error]
    assert_equal [ 2 ], status[:runs].map { |run| run[:id] }
  end

end

require "test_helper"

class Admin::DeploysControllerTest < ActionDispatch::IntegrationTest

  setup do
    @calls = []
    calls = @calls
    @original_transport = HouseDeploy.transport
    HouseDeploy.transport = lambda do |method, path, body|
      calls << [ method, path, body ]
      method == :post ? [ 204, {}, nil ] : [ 200, {}, { "workflow_runs" => [] } ]
    end
    @original_token_source = HouseDeploy.token_source
    HouseDeploy.token_source = -> { "github_pat_test" }
  end

  teardown do
    HouseDeploy.transport = @original_transport
    HouseDeploy.token_source = @original_token_source
  end

  test "non-admins are sent away and nothing is dispatched" do
    sign_in users(:user_1)

    get admin_deploys_path
    assert_redirected_to root_path

    post admin_deploys_path, params: { workflow: "rails" }
    assert_redirected_to root_path
    assert_empty @calls
  end

  test "unauthenticated users cannot dispatch" do
    post admin_deploys_path, params: { workflow: "rails" }

    assert_redirected_to login_path
    assert_empty @calls
  end

  test "site admin sees the workflows and status" do
    sign_in users(:site_admin_user)

    get admin_deploys_path

    assert_response :success
    assert_equal "admin/deploys", inertia_component
    props = inertia_shared_props
    assert_equal %w[rails runtime chaos both], props["workflows"].map { |w| w["key"] }
    assert props["deploy_status"]["configured"]
  end

  test "site admin dispatch calls GitHub and writes an audit log" do
    sign_in users(:site_admin_user)

    assert_difference -> { AuditLog.where(action: "admin_deploy_dispatched").count }, 1 do
      post admin_deploys_path, params: { workflow: "chaos" }
    end

    assert_redirected_to admin_deploys_path
    assert_equal [ :post, "/repos/swombat/souls-house/actions/workflows/deploy-chaos.yml/dispatches", { ref: "master" } ], @calls.last
    assert_equal "chaos", AuditLog.where(action: "admin_deploy_dispatched").last.data["workflow"]
  end

  test "unknown workflow is refused and audited as a failure" do
    sign_in users(:site_admin_user)

    assert_difference -> { AuditLog.where(action: "admin_deploy_failed").count }, 1 do
      post admin_deploys_path, params: { workflow: "ci" }
    end

    assert_redirected_to admin_deploys_path
    assert_empty @calls
    assert_match(/Unknown deploy/, flash[:alert])
  end

end

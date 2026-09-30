require "test_helper"

class Admin::JobsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @admin = users(:site_admin_user)
    @user = users(:user_1)
  end

  # === Authorization Tests ===

  test "index redirects non-admin users to root" do
    sign_in @user
    get admin_jobs_path
    assert_redirected_to root_path
  end

  test "index redirects unauthenticated users" do
    get admin_jobs_path
    assert_redirected_to login_path
  end

  test "index renders successfully for site admins" do
    sign_in @admin
    get admin_jobs_path
    assert_response :success
    assert_equal "admin/jobs", inertia_component
  end

  test "index returns jobs list in props" do
    sign_in @admin
    get admin_jobs_path
    assert_response :success

    props = inertia_shared_props
    assert props.key?("jobs")

    jobs = props["jobs"]
    assert jobs.is_a?(Array)
    assert jobs.size > 0

    job = jobs.find { |j| j["key"] == "cleanup_orphaned_messages" }
    assert job.present?
    assert_equal "Cleanup Orphaned Messages", job["name"]
    assert job["description"].present?

    reconcile_job = jobs.find { |j| j["key"] == "hosted_agent_runtime_reconcile" }
    assert reconcile_job.present?
    assert_equal "Reconcile Hosted Resident Runtime", reconcile_job["name"]
  end

  # === Create Action Authorization Tests ===

  test "create redirects non-admin users to root" do
    sign_in @user
    post admin_jobs_path, params: { job_key: "cleanup_orphaned_messages" }
    assert_redirected_to root_path
  end

  test "create redirects unauthenticated users" do
    post admin_jobs_path, params: { job_key: "cleanup_orphaned_messages" }
    assert_redirected_to login_path
  end

  # === Create Action Functional Tests ===

  test "create enqueues the job for valid job_key" do
    sign_in @admin

    assert_enqueued_with(job: CleanupOrphanedMessagesJob) do
      post admin_jobs_path, params: { job_key: "cleanup_orphaned_messages" }
    end

    assert_redirected_to admin_jobs_path
    assert_equal "Cleanup Orphaned Messages has been queued.", flash[:notice]
  end

  test "create redirects with alert for unknown job_key" do
    sign_in @admin
    post admin_jobs_path, params: { job_key: "nonexistent_job" }

    assert_redirected_to admin_jobs_path
    assert_equal "Unknown job: nonexistent_job", flash[:alert]
  end

  test "create redirects with alert when job_key is missing" do
    sign_in @admin
    post admin_jobs_path

    assert_redirected_to admin_jobs_path
    assert_match(/Unknown job/, flash[:alert])
  end

end

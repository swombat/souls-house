require "test_helper"

class Admin::ResidentMigrationsControllerTest < ActionDispatch::IntegrationTest

  # Stands in for the read-only Docker capture of the resident's volumes.
  class HouseTransport

    def stopped! = true

    def capture(root, output)
      Gem::Package::TarWriter.new(output) do |tar|
        tar.mkdir(".", 0755)
        body = "#{root} as lived on the house"
        tar.add_file_simple("./#{root}.md", 0644, body.bytesize) { |file| file.write(body) }
      end
    end

  end

  setup do
    @agent = accounts(:personal_account).agents.create!(name: "Moving resident", runtime: "offline", active: false,
      paused: true, home_profile: "house", uuid: SecureRandom.uuid_v7,
      model_id: HouseInference::Offering::OFFERINGS.keys.first)
    @agent.update_columns(runtime_ready_at: 2.days.ago)
    Setting.instance.update!(new_residents_on_vm: false)
  end

  test "the dry run shows every gate and changes nothing" do
    sign_in users(:site_admin_user)
    get admin_agent_migration_path(@agent)
    assert_response :success
    assert_equal "admin/resident-migration", inertia_component
    report = inertia_props["props"]["report"]
    assert_equal 7, report["gates"].size
    assert_equal Agents::VmMigration::SWITCHED_OFF, report["gates"].first["refusal"]
    assert_empty report["roles"], "sizes are measured only when asked"
    assert_equal Agents::VmMigration::Plan::FACTS, report["facts"]
    assert_nil @agent.reload.placement
  end

  test "measuring reads the volumes through the transport and records who asked" do
    sign_in users(:site_admin_user)
    Agents::Portability::Transport.stub(:new, HouseTransport.new) do
      post measure_admin_agent_migration_path(@agent)
    end
    report = inertia_props["props"]["report"]
    assert_equal %w[identity repo work], report["roles"].map { |role| role["role"] }
    assert(report["roles"].all? { |role| role["fits"] })
    assert AuditLog.exists?(action: "vm_migration_dry_run", auditable: @agent, user: users(:site_admin_user))
    assert_empty @agent.reload.import_stages
  end

  test "a GET never measures, even with the old parameter" do
    sign_in users(:site_admin_user)
    get admin_agent_migration_path(@agent, measure: 1)
    assert_empty inertia_props["props"]["report"]["roles"]
    assert_not AuditLog.exists?(action: "vm_migration_dry_run", auditable: @agent)
  end

  test "the real run goes through the same refusals: switched off, it is not moved" do
    sign_in users(:site_admin_user)
    post admin_agent_migration_path(@agent)
    assert_redirected_to admin_agent_migration_path(@agent)
    assert_equal "Not moved: #{Agents::VmMigration::SWITCHED_OFF}", flash[:alert]
    assert_nil @agent.reload.placement
    assert @agent.runtime_ready_at
  end

  test "only site admins reach it" do
    sign_in users(:user_1)
    get admin_agent_migration_path(@agent)
    assert_redirected_to root_path
    post admin_agent_migration_path(@agent)
    assert_redirected_to root_path
    post measure_admin_agent_migration_path(@agent)
    assert_redirected_to root_path
    assert_nil @agent.reload.placement
  end

end

require "test_helper"
require "rake"

# vm:migrate (#426 slice 3B): the shell way in for one named resident.
class VmMigrateRakeTest < ActiveSupport::TestCase

  # Stands in for the read-only Docker capture of the resident's volumes.
  class HouseTransport

    def capture(root, output)
      Gem::Package::TarWriter.new(output) do |tar|
        tar.mkdir(".", 0755)
        body = "#{root} as lived on the house"
        tar.add_file_simple("./#{root}.md", 0644, body.bytesize) { |file| file.write(body) }
      end
    end

  end

  # Records the one call apply makes, and answers the gates for the report.
  class FakeMigration

    attr_reader :agent, :gates, :moved_by

    # Built before Agents::VmMigration.new is stubbed to return this.
    def initialize(agent, refuse: nil)
      @agent = agent
      @refuse = refuse
      @gates = Agents::VmMigration.new(agent).gates
    end

    def move!(requested_by:)
      raise Agents::VmMigration::Refused, @refuse if @refuse

      @moved_by = requested_by
      AgentPlacement.new(id: 0, generation: 1).tap { |placement| placement.define_singleton_method(:reload) { self } }
    end

  end

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("vm:migrate")
    @task = Rake::Task["vm:migrate"]
    @task.reenable
    @admin = users(:site_admin_user)
    @agent = accounts(:personal_account).agents.create!(name: "Moving resident", runtime: "offline", active: false,
      paused: true, home_profile: "house", uuid: SecureRandom.uuid_v7,
      model_id: HouseInference::Offering::OFFERINGS.keys.first)
    @agent.update_columns(runtime_ready_at: 2.days.ago)
    Setting.instance.update!(new_residents_on_vm: false)
  end

  def run_task(env)
    saved = env.keys.to_h { |key| [ key, ENV[key] ] }
    env.each { |key, value| ENV[key] = value }
    output = StringIO.new
    status = nil
    $stdout = output
    begin
      @task.invoke(@agent.id.to_s)
    rescue SystemExit => exit
      status = exit
    ensure
      $stdout = STDOUT
      saved.each { |key, value| ENV[key] = value }
    end
    [ output.string, status ]
  end

  test "by default it is a dry run that measures, and changes nothing" do
    output, status = Agents::Portability::Transport.stub(:new, HouseTransport.new) do
      run_task("REQUESTED_BY" => @admin.email_address, "MEASURE" => nil, "MODE" => nil)
    end
    assert_nil status
    report = JSON.parse(output)
    assert_equal %w[identity repo work], report["roles"].map { |role| role["role"] }
    assert report["whole"]["fits"]
    assert_equal Agents::VmMigration::SWITCHED_OFF, report["gates"].first["refusal"]
    assert AuditLog.exists?(action: "vm_migration_dry_run", auditable: @agent, user: @admin)
    assert_nil @agent.reload.placement
  end

  test "MEASURE=0 answers the gates and reads no volume" do
    output, status = Agents::Portability::Transport.stub(:new, ->(*) { flunk "no volume is read" }) do
      run_task("REQUESTED_BY" => @admin.email_address, "MEASURE" => "0", "MODE" => nil)
    end
    assert_nil status
    report = JSON.parse(output)
    assert_empty report["roles"]
    assert_equal 7, report["gates"].size
    assert_not AuditLog.exists?(action: "vm_migration_dry_run", auditable: @agent)
  end

  test "only a site admin may ask, for a dry run or a move" do
    [ nil, users(:user_1).email_address, "nobody@example.invalid" ].each do |requester|
      @task.reenable
      _output, status = run_task("REQUESTED_BY" => requester, "MEASURE" => "0", "MODE" => "apply")
      assert status, "refused for #{requester.inspect}"
      assert_not status.success?
    end
    assert_nil @agent.reload.placement
  end

  test "MODE=apply goes through move! and reports a refusal in its own words" do
    moving = FakeMigration.new(@agent)
    output, status = Agents::VmMigration.stub(:new, moving) do
      run_task("REQUESTED_BY" => @admin.email_address, "MEASURE" => "0", "MODE" => "apply")
    end
    assert_nil status
    assert_equal @admin, moving.moved_by
    assert_match(/Staged and admitted/, output)

    @task.reenable
    refused = FakeMigration.new(@agent, refuse: Agents::VmMigration::SWITCHED_OFF)
    _output, status = Agents::VmMigration.stub(:new, refused) do
      run_task("REQUESTED_BY" => @admin.email_address, "MEASURE" => "0", "MODE" => "apply")
    end
    assert_not status.success?
    assert_match(/Refused: #{Regexp.escape(Agents::VmMigration::SWITCHED_OFF)}/, status.message)
  end

  test "without MODE=apply nothing is moved" do
    moving = FakeMigration.new(@agent)
    Agents::VmMigration.stub(:new, moving) do
      run_task("REQUESTED_BY" => @admin.email_address, "MEASURE" => "0", "MODE" => nil)
    end
    assert_nil moving.moved_by
  end

end

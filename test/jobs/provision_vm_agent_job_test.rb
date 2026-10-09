require "test_helper"

# A whole VM birth (#246 slice 5) against a fake provider and a fake slice-4
# backup seam: admission, order, enrollment, seed, start, first backup, and
# only then a dispatchable resident. Plus the ways a birth fails and is
# cleaned up.
class ProvisionVmAgentJobTest < ActiveJob::TestCase

  IMAGE = "sha256:#{'c' * 64}".freeze
  IMAGE_ID = 161_547_269

  class FakeClient

    attr_reader :creates, :deletes
    attr_accessor :servers, :actions, :on_create

    def initialize
      @creates = []
      @deletes = []
      @servers = {}
      @actions = {}
    end

    def create_server_with_action(**kwargs)
      @creates << kwargs
      on_create.call(kwargs)
    end

    def find_server(id) = servers[id]
    def find_by_operation(public_id) = servers.values.select { |server| server.operation_id == public_id }
    def find_action(id) = actions[id]
    def create_actions_for(_server_id) = []

    def delete_server(id, placement_id:)
      @deletes << [ id, placement_id ]
      servers.delete(id)
      HetznerCloudClient::DeleteAccepted.new(server_id: id, action_id: 900 + @deletes.size, action_status: "running")
    end

  end

  # Stands in for slice 4's Backup::VmResident until it is merged; with it
  # merged, its two seam methods are stubbed instead.
  class FakeBackups

    attr_accessor :state, :issued

    def initialize
      @state = "pending"
      @issued = []
    end

    def issue!(placement:)
      enrollment = RunnerEnrollment.where(agent_placement_id: placement.id, revoked_at: nil).order(:id).last
      kind = RunnerCommand::KINDS.include?("backup_resident") ? "backup_resident" : "turn_status"
      command = RunnerCommand.enqueue!(enrollment:, kind:, payload: { "fake" => "backup" })
      @issued << command
      command
    end

    attr_accessor :hold_after_failure

    def status(command:)
      { state: state, reason: state == "failed" ? "snapshot missing" : nil, snapshot: nil }
    end

    def held?(_agent)
      state == "failed" && hold_after_failure == true
    end

    attr_reader :released

    attr_accessor :release_failures, :on_release

    def release_after_retirement!(placement:)
      if (release_failures || 0).positive?
        self.release_failures -= 1
        raise "transient release failure"
      end
      (@released ||= []) << placement.id
      on_release&.call(placement)
    end

  end

  setup do
    @setting = Setting.instance
    @setting.update!(new_residents_on_vm: true, vm_resident_limit: 2)
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @client = FakeClient.new
    @tokens = []
    tokens = @tokens
    renderer = Object.new
    renderer.define_singleton_method(:render) { |enrollment:, token:, **| tokens << token; "#cloud-config\n" }
    @config = CloudProcurement::Config.new(image_id: IMAGE_ID, ssh_key_ids: [ 101 ], locations: %w[fsn1],
      rails_url: "https://souls.example", runner_commands: true)
    client = @client
    config = @config
    ProvisionVmAgentJob.procurement_factory = -> { CloudProcurement.new(client:, config:, renderer:) }
    @client.on_create = lambda do |kwargs|
      server = fake_server(id: 4242, status: "initializing", name: kwargs[:name], placement_id: kwargs[:placement_id],
        operation_id: kwargs[:labels][HetznerCloudClient::OPERATION_LABEL], location: kwargs[:location])
      @client.servers[server.id] = server
      @client.actions[77] = HetznerCloudClient::Action.new(id: 77, command: "create_server", status: "running", error_code: nil)
      HetznerCloudClient::Created.new(server:, action_id: 77, action_status: "running")
    end
    @backups = FakeBackups.new
    @previous_env = %w[SOULSHOUSE_DOMAIN HOUSE_INFERENCE_OPENROUTER_API_KEY].to_h { |key| [ key, ENV[key] ] }
    ENV["SOULSHOUSE_DOMAIN"] = "souls.example"
    ENV["HOUSE_INFERENCE_OPENROUTER_API_KEY"] = "test-key"
  end

  teardown do
    ProvisionVmAgentJob.procurement_factory = -> { CloudProcurement.from_credentials }
    @previous_env.each { |key, value| ENV[key] = value }
  end

  def fake_server(id:, status:, name:, placement_id:, operation_id:, location:)
    labels = { HetznerCloudClient::MANAGED_LABEL => "true", HetznerCloudClient::PLACEMENT_LABEL => placement_id,
               HetznerCloudClient::OPERATION_LABEL => operation_id }
    HetznerCloudClient::Server.new(id:, name:, status:, server_type: "cx23", location:, image_id: IMAGE_ID,
      ipv4: "203.0.113.9", ipv6: "2001:db8::/64", labels:)
  end

  # Everything that needs the outside world, faked: VM backups, procurement
  # configuration, and the house's local image ID.
  def with_house(&block)
    policy_config = @config
    Agents::VmBirthPolicy.stub(:current, -> { Agents::VmBirthPolicy.new(setting: Setting.instance, procurement_config: policy_config, api_token: "token") }) do
      with_backups do
        Agents::RemoteRuntime.stub(:local_image_id, IMAGE) do
          ResidentTurn.stub(:enabled?, true, &block)
        end
      end
    end
  end

  def with_backups(&block)
    if Backup.const_defined?(:VmResident)
      Backup::VmResident.stub(:issue!, ->(**kwargs) { @backups.issue!(**kwargs) }) do
        Backup::VmResident.stub(:status, ->(**kwargs) { @backups.status(**kwargs) }) do
          Backup::VmResident.stub(:held?, ->(agent) { @backups.held?(agent) }) do
            Backup::VmResident.stub(:release_after_retirement!, ->(**kwargs) { @backups.release_after_retirement!(**kwargs) }, &block)
          end
        end
      end
    else
      Backup.const_set(:VmResident, @backups)
      begin
        yield
      ensure
        Backup.send(:remove_const, :VmResident)
      end
    end
  end

  def born!(model_id: HouseInference::Offering::OFFERINGS.keys.first)
    Agents::HostedBirth.new(account: @account, creator: @user,
      attributes: { name: "Vm born", system_prompt: "Hello", model_id: }).create!
  end

  def run_job(agent)
    ProvisionVmAgentJob.perform_now(agent.id)
    agent.reload
  end

  def operation(agent) = agent.placement.reload.cloud_procurement_operations.order(:id).last

  def answer_latest(placement, kind, outcome = "done")
    command = RunnerCommand.where(agent_placement_id: placement.id, kind:).order(:id).last
    command.deliver!(now: Time.current) unless command.delivered?
    command.record_result!({ "outcome" => outcome }, now: Time.current)
  end

  def boot_and_enroll!(agent)
    @client.actions[77] = HetznerCloudClient::Action.new(id: 77, command: "create_server", status: "success", error_code: nil)
    @client.servers[4242] = @client.servers[4242].with(status: "running")
    run_job(agent)
    assert_equal "provisioned", operation(agent).state
    enrollment = operation(agent).runner_enrollment
    enrollment.enroll!(token: @tokens.last, public_key: Base64.strict_encode64("k" * 32), reported_server_id: 4242,
      facts: {}, nonce: SecureRandom.hex(16))
    enrollment.heartbeat!(reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
  end

  test "a whole birth: order, enroll, seed, start, verified backup, and only then dispatchable" do
    with_house do
      agent = nil
      assert_enqueued_with(job: ProvisionVmAgentJob) { agent = born! }
      placement = agent.placement
      assert placement.vm_birth?
      assert_equal "pending", placement.state
      assert_equal @user, placement.birth_requested_by
      assert_in_delta 45.minutes.from_now, placement.birth_deadline_at, 5
      assert_equal "hk-agent-#{agent.uuid}", agent.container_name
      assert agent.trigger_bearer_token.present?

      run_job(agent)
      assert_equal 1, @client.creates.size
      assert_equal "reconciling", operation(agent).state
      assert_equal "setting:new_residents_on_vm/agent:#{agent.id}", operation(agent).approval_reference
      assert AuditLog.exists?(action: "vm_birth_procurement_planned", auditable: operation(agent))

      run_job(agent) # still booting
      assert_equal 1, @client.creates.size, "never a second order"

      boot_and_enroll!(agent)
      run_job(agent)
      assert_equal "seed_home", RunnerCommand.where(agent_placement_id: placement.id).order(:id).last.kind
      answer_latest(placement, "seed_home")

      run_job(agent)
      assert_equal "ready", placement.reload.state
      start = RunnerCommand.where(agent_placement_id: placement.id, kind: "start_resident").last
      assert_equal IMAGE, JSON.parse(start.payload_json)["image"]
      answer_latest(placement, "start_resident")

      # Ready, healthy runner, resident started - and still nothing dispatches.
      assert_nil Agents::RemoteRuntime.enrollment_for(agent.reload)

      run_job(agent)
      assert_equal 1, @backups.issued.size
      assert_equal @backups.issued.last.id, placement.reload.first_backup_command_id
      run_job(agent)
      assert_nil agent.runtime_ready_at, "a pending backup is not a verified one"

      @backups.state = "verified"
      assert_enqueued_with(job: OrientNewAgentJob, args: [ agent.id ]) { run_job(agent) }
      assert agent.runtime_ready_at
      assert_equal "external", agent.runtime
      assert_equal "healthy", agent.health_state
      assert Agents::RemoteRuntime.enrollment_for(agent)
      assert_equal 1, @client.creates.size
    end
  end

  test "switching the setting off after admission does not strand the birth" do
    with_house do
      agent = born!
      @setting.update!(new_residents_on_vm: false)
      run_job(agent)
      assert_equal 1, @client.creates.size
    end
  end

  test "a refused order fails the birth, and cleanup retires the placement and frees the slot" do
    with_house do
      agent = born!
      @client.on_create = ->(_) { raise HetznerCloudClient::Error.new("no capacity", status: 412, code: "resource_unavailable") }
      assert_enqueued_with(job: VmCleanupJob) { run_job(agent) }
      placement = agent.placement.reload
      assert_equal "failed", placement.state
      assert placement.cleanup_requested?
      assert_match(/refused/, agent.sandbox_last_error)
      assert_nil agent.runtime_ready_at
      assert_equal 1, Agents::VmBirthPolicy.current.vm_count

      VmCleanupJob.perform_now(placement.id)
      assert_equal "retired", placement.reload.state
      assert_equal 0, Agents::VmBirthPolicy.current.vm_count
    end
  end

  test "past the deadline a provisioned server is deleted, deletion confirmed, enrollment revoked" do
    with_house do
      agent = born!
      run_job(agent)
      boot_and_enroll!(agent)
      travel 46.minutes do
        run_job(agent)
        placement = agent.placement.reload
        assert_match(/deadline/, agent.sandbox_last_error)
        assert_equal "failed", placement.state

        VmCleanupJob.perform_now(placement.id)
        assert_equal [ [ 4242, placement.id.to_s ] ], @client.deletes
        VmCleanupJob.perform_now(placement.id)
        assert_equal "deleted", operation(agent).state
        assert_equal "retired", placement.reload.state
        assert operation(agent).runner_enrollment.reload.revoked_at
        assert_nil Agents::RemoteRuntime.enrollment_for(agent)
        assert_equal [ placement.id ], @backups.released.uniq, "backup holds are released only after retirement"
      end
    end
  end

  test "a failed seed is retried, and a refused one fails the birth" do
    with_house do
      agent = born!
      run_job(agent)
      boot_and_enroll!(agent)
      run_job(agent)
      answer_latest(agent.placement, "seed_home", "failed")
      run_job(agent)
      assert_equal 2, RunnerCommand.where(agent_placement_id: agent.placement.id, kind: "seed_home").count
      answer_latest(agent.placement, "seed_home", "refused")
      run_job(agent)
      assert_match(/could not be seeded/, agent.sandbox_last_error)
      assert_equal "failed", agent.placement.reload.state
      assert_equal 0, RunnerCommand.where(agent_placement_id: agent.placement.id, kind: "start_resident").count
    end
  end

  test "a failed first backup that kept its hold fails the birth at once and cleans up" do
    with_house do
      agent = born!
      run_job(agent)
      boot_and_enroll!(agent)
      run_job(agent)
      answer_latest(agent.placement, "seed_home")
      run_job(agent)
      answer_latest(agent.placement, "start_resident")
      run_job(agent)
      @backups.state = "failed"
      @backups.hold_after_failure = true
      assert_enqueued_with(job: VmCleanupJob) { run_job(agent) }
      assert_equal 1, @backups.issued.size, "no retry into a held backup"
      assert_match(/unknown state/, agent.sandbox_last_error)
      assert_equal "failed", agent.placement.reload.state
    end
  end

  test "three failed first backups fail the birth; no orientation" do
    with_house do
      agent = born!
      run_job(agent)
      boot_and_enroll!(agent)
      run_job(agent)
      answer_latest(agent.placement, "seed_home")
      run_job(agent)
      answer_latest(agent.placement, "start_resident")
      @backups.state = "failed"
      assert_no_enqueued_jobs(only: OrientNewAgentJob) do
        5.times { run_job(agent) }
      end
      assert_equal 3, @backups.issued.size
      assert_match(/first backup failed/, agent.sandbox_last_error)
      assert_nil agent.runtime_ready_at
    end
  end

  test "admission is capped under the lock, and only house-inference residents are born on a VM for now" do
    with_house do
      @setting.update!(vm_resident_limit: 1)
      born!
      HouseInferenceGrant.where(user: @user).update_all(agent_id: nil)
      error = assert_raises(Agents::VmBirthPolicy::Refused) { born! }
      assert_equal Agents::VmBirthPolicy::LIMIT_REFUSAL, error.message

      @setting.update!(vm_resident_limit: 5)
      assert_no_difference [ "Agent.count", "AgentPlacement.count" ] do
        error = assert_raises(Agents::VmBirthPolicy::Refused) { born!(model_id: "openrouter/auto") }
        assert_equal Agents::VmBirthPolicy::MODEL_REFUSAL, error.message
      end
    end
  end

  test "only an admitted VM birth can buy without an admin" do
    placement = AgentPlacement.create!(agent: agents(:code_reviewer), backend: "hetzner_cloud", state: "pending")
    assert_raises(CloudProcurement::NotAllowed) { ProvisionVmAgentJob.procurement_factory.call.plan_for_vm_birth!(placement:) }
    placement.update!(admitted_by_setting_at: Time.current, birth_requested_by: @user, cleanup_requested_at: Time.current)
    assert_raises(CloudProcurement::NotAllowed) { ProvisionVmAgentJob.procurement_factory.call.plan_for_vm_birth!(placement:) }
    assert_equal 0, CloudProcurementOperation.count
  end

  test "the sweep re-enqueues births in progress and cleanups not yet retired" do
    with_house do
      agent = born!
      failed = AgentPlacement.create!(agent: agents(:code_reviewer), backend: "hetzner_cloud", state: "failed",
        cleanup_requested_at: Time.current, cleanup_reason: "test")
      assert_enqueued_with(job: ProvisionVmAgentJob, args: [ agent.id ]) do
        assert_enqueued_with(job: VmCleanupJob, args: [ failed.id ]) { VmBirthSweepJob.perform_now }
      end
    end
  end


  # --- lifecycle lock (Mira's #269 review) -------------------------------

  def contender
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    # nil fields are left out so libpq falls back to PGHOST and friends, as
    # Active Record's own connection does.
    PG.connect(**{ dbname: config[:database], host: config[:host], port: config[:port],
      user: config[:username], password: config[:password] }.compact)
  end

  def held_elsewhere?(placement_id, connection)
    key = "#{ProvisionVmAgentJob::LOCK_CLASS}, #{placement_id}"
    got = connection.exec("SELECT pg_try_advisory_lock(#{key})").getvalue(0, 0) == "t"
    connection.exec("SELECT pg_advisory_unlock(#{key})") if got
    !got
  end

  test "the lifecycle lock really is taken on every run, even with the query cache on" do
    other = contender
    observed = []
    ActiveRecord::Base.cache do
      3.times do
        result = ProvisionVmAgentJob.exclusively(4242) { observed << held_elsewhere?(4242, other); :ran }
        assert_equal :ran, result
      end
    end
    assert_equal [ true, true, true ], observed, "each run must hold the lock for real"
    assert_not held_elsewhere?(4242, other), "and release it afterwards"
  ensure
    other&.close
  end

  test "a run finds the lock busy while another connection holds it" do
    other = contender
    other.exec("SELECT pg_advisory_lock(#{ProvisionVmAgentJob::LOCK_CLASS}, 4243)")
    assert_equal :busy, ProvisionVmAgentJob.exclusively(4243) { flunk "must not run" }
  ensure
    other&.close
  end

  test "when cleanup wins, a late birth step orders nothing, starts nothing and finishes nothing" do
    with_house do
      agent = born!
      placement = agent.placement
      placement.request_cleanup!("operator")
      VmCleanupJob.perform_now(placement.id)
      assert_equal "retired", placement.reload.state
      assert_no_enqueued_jobs(only: OrientNewAgentJob) { run_job(agent) }
      assert_empty @client.creates
      assert_equal 0, CloudProcurementOperation.where(agent_placement_id: placement.id).count
      assert_nil agent.runtime_ready_at
    end
  end

  test "procurement re-checks cleanup under the placement lock, whatever the caller last read" do
    with_house do
      agent = born!
      stale = AgentPlacement.find(agent.placement.id)
      AgentPlacement.where(id: stale.id).update_all(cleanup_requested_at: Time.current, cleanup_reason: "late")
      procurement = ProvisionVmAgentJob.procurement_factory.call
      assert_raises(CloudProcurement::NotAllowed) do
        procurement.send(:plan_operation!, placement: stale, requested_by: @user, approval_reference: "x",
          server_type: "cx23", refuse_if_cleanup_requested: true)
      end
      assert_equal 0, CloudProcurementOperation.where(agent_placement_id: stale.id).count
    end
  end

  test "retirement re-checks unresolved purchases under its lock, and release is retried once retired" do
    with_house do
      agent = born!
      run_job(agent)
      placement = agent.placement.reload
      placement.request_cleanup!("operator")
      job = VmCleanupJob.new
      job.send(:retire!, placement)
      assert_equal "pending", placement.reload.state, "an unresolved purchase blocks retirement"

      placement.cloud_procurement_operations.update_all(state: "deleted")
      job.send(:retire!, placement)
      assert_equal "retired", placement.reload.state
      assert_equal [ placement.id ], @backups.released
      VmCleanupJob.perform_now(placement.id)
      assert_equal [ placement.id, placement.id ], @backups.released, "a retired placement still retries the release"
    end
  end


  test "a release that failed after retirement is retried by the sweep, and finished placements stay out of it" do
    with_house do
      agent = born!
      placement = agent.placement
      placement.update!(cleanup_requested_at: Time.current, cleanup_reason: "operator", state: "retired")
      enrollment, = RunnerEnrollment.mint!(placement:)
      command = RunnerCommand.enqueue!(enrollment:, kind: "backup_resident", payload: {})
      backup = VmBackup.create!(agent:, runner_command: command, checkpoint_file_digest: "x", deadline_at: 1.hour.from_now)

      assert_enqueued_with(job: VmCleanupJob, args: [ placement.id ]) { VmBirthSweepJob.perform_now }
      @backups.release_failures = 1
      @backups.on_release = ->(_) { backup.update!(released_at: Time.current) }
      VmCleanupJob.perform_now(placement.id) # fails transiently, logged and swallowed
      assert_nil backup.reload.released_at
      assert_enqueued_with(job: VmCleanupJob, args: [ placement.id ]) { VmBirthSweepJob.perform_now }
      VmCleanupJob.perform_now(placement.id)
      assert backup.reload.released_at
      clear_enqueued_jobs
      VmBirthSweepJob.perform_now
      assert_no_enqueued_jobs(only: VmCleanupJob) # a retired placement with nothing held is finished
    end
  end

end

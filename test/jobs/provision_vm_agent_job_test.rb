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

    def status(command:)
      { state: state, reason: state == "failed" ? "snapshot missing" : nil, snapshot: nil }
    end

    attr_reader :released

    def release_after_retirement!(placement:)
      (@released ||= []) << placement.id
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
          Backup::VmResident.stub(:release_after_retirement!, ->(**kwargs) { @backups.release_after_retirement!(**kwargs) }, &block)
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

  def born!(model_id: HouseInference::Offering::MODEL_ID)
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
        assert_equal [ placement.id ], @backups.released, "backup holds are released only after retirement"
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

end

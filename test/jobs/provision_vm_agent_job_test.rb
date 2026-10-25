require "test_helper"
require_relative "../support/github_import_fixtures"

# A whole VM birth (#246 slice 5) against a fake provider and a fake slice-4
# backup seam: admission, order, enrollment, seed, start, first backup, and
# only then a dispatchable resident. Plus the ways a birth fails and is
# cleaned up.
class ProvisionVmAgentJobTest < ActiveJob::TestCase

  include GithubImportFixtures

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
    serve_creates_as(4242)
    @backups = FakeBackups.new
    @previous_env = %w[SOULSHOUSE_DOMAIN HOUSE_INFERENCE_OPENROUTER_API_KEY].to_h { |key| [ key, ENV[key] ] }
    ENV["SOULSHOUSE_DOMAIN"] = "souls.example"
    ENV["HOUSE_INFERENCE_OPENROUTER_API_KEY"] = "test-key"
  end

  teardown do
    ProvisionVmAgentJob.procurement_factory = -> { CloudProcurement.from_credentials }
    @previous_env.each { |key, value| ENV[key] = value }
  end

  # The next create answers with this server id. A retried activation buys a
  # new server, which the provider gives a new id.
  def serve_creates_as(server_id)
    @server_id = server_id
    @client.on_create = lambda do |kwargs|
      server = fake_server(id: server_id, status: "initializing", name: kwargs[:name], placement_id: kwargs[:placement_id],
        operation_id: kwargs[:labels][HetznerCloudClient::OPERATION_LABEL], location: kwargs[:location])
      @client.servers[server.id] = server
      @client.actions[77] = HetznerCloudClient::Action.new(id: 77, command: "create_server", status: "running", error_code: nil)
      HetznerCloudClient::Created.new(server:, action_id: 77, action_status: "running")
    end
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

  def born!(model_id: HouseInference::Offering::OFFERINGS.keys.first, name: "Vm born")
    Agents::HostedBirth.new(account: @account, creator: @user,
      attributes: { name:, system_prompt: "Hello", model_id: }).create!
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
    @client.servers[@server_id] = @client.servers[@server_id].with(status: "running")
    run_job(agent)
    assert_equal "provisioned", operation(agent).state
    enrollment = operation(agent).runner_enrollment
    enrollment.enroll!(token: @tokens.last, public_key: Base64.strict_encode64("k" * 32), reported_server_id: @server_id,
      facts: {}, nonce: SecureRandom.hex(16))
    enrollment.heartbeat!(reported_server_id: @server_id, facts: {}, nonce: SecureRandom.hex(16))
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
      assert_equal [], progress(agent)

      run_job(agent)
      assert_equal 1, @client.creates.size
      assert_equal "reconciling", operation(agent).state
      assert_equal "setting:new_residents_on_vm/agent:#{agent.id}", operation(agent).approval_reference
      assert AuditLog.exists?(action: "vm_birth_procurement_planned", auditable: operation(agent))

      run_job(agent) # still booting
      assert_equal 1, @client.creates.size, "never a second order"

      boot_and_enroll!(agent)
      run_job(agent)
      assert_equal %w[server_ordered server_online], progress(agent)
      assert_equal "seed_home", RunnerCommand.where(agent_placement_id: placement.id).order(:id).last.kind
      answer_latest(placement, "seed_home")
      assert_equal %w[server_ordered server_online home_prepared], progress(agent)

      run_job(agent)
      assert_equal "ready", placement.reload.state
      start = RunnerCommand.where(agent_placement_id: placement.id, kind: "start_resident").last
      assert_equal IMAGE, JSON.parse(start.payload_json)["image"]
      answer_latest(placement, "start_resident")
      assert_equal %w[server_ordered server_online home_prepared runtime_started], progress(agent)

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
      assert_equal %w[server_ordered server_online home_prepared runtime_started first_backup], progress(agent)
      assert_equal({}, Agents::DailyJournalStatus.new(agent).snapshot,
        "its first wake reads no local container: there is none, and asking for one failed the wake")
    end
  end

  # What the onboarding page shows as done (Agents::VmBirthProgress).
  def progress(agent)
    Agents::VmBirthProgress.for(agent.reload).select { |step| step[:done] }.map { |step| step[:key] }
  end

  # An archive import staged for its own server, as Portability::Import
  # leaves it (#438), with three staged role homes.
  def staged_import!(name: "Imported copy")
    agent = @account.agents.create!(name:, model_id: HouseInference::Offering::OFFERINGS.keys.first, runtime: "provisioning",
      active: false, paused: true, scheduled_wakes_enabled: false, home_profile: "house",
      portability_custody: { "export_id" => SecureRandom.uuid })
    AgentPlacement.create!(agent:, backend: "hetzner_cloud", kind: "archive_import", state: "staged")
    Agents::HostedProvisioning.new(agent:, user: @user).prepare!(started_at: Time.current)
    agent.update_columns(runtime: "offline")
    AgentImportStage::ROLES.each do |role|
      bytes = Zlib.gzip("#{role} home")
      agent.import_stages.create!(role:, archive: bytes, sha256: Digest::SHA256.hexdigest(bytes), bytes: bytes.bytesize)
    end
    agent.reload
  end

  test "a whole archive activation: admitted at Activate, three roles seeded, started, backed up, then active with no orientation" do
    with_house do
      agent = staged_import!
      placement = agent.placement
      assert_equal 0, Agents::VmBirthPolicy.current.vm_count
      run_job(agent)
      assert_empty @client.creates, "a staged copy orders nothing"

      Agents::VmBirthPolicy.current.admit_import!(placement:, requested_by: @user)
      placement.reload
      assert_equal "pending", placement.state
      assert placement.vm_birth?
      assert_equal @user, placement.birth_requested_by
      assert_in_delta 45.minutes.from_now, placement.birth_deadline_at, 5
      assert_equal 1, Agents::VmBirthPolicy.current.vm_count

      run_job(agent)
      assert_equal 1, @client.creates.size
      boot_and_enroll!(agent)
      operation(agent).runner_enrollment.update!(last_facts: { "seed_roles" => AgentImportStage::ROLES })
      run_job(agent)
      seeds = RunnerCommand.where(agent_placement_id: placement.id, kind: "seed_home").order(:id)
      assert_equal %w[identity repo work], seeds.map(&:seed_role)
      seeds.each { |command| command.deliver!(now: Time.current); command.record_result!({ "outcome" => "done" }, now: Time.current) }

      run_job(agent)
      assert_equal "ready", placement.reload.state
      answer_latest(placement, "start_resident")
      run_job(agent)
      @backups.state = "verified"
      assert_no_enqueued_jobs(only: OrientNewAgentJob) { run_job(agent) }
      assert agent.runtime_ready_at
      assert agent.active?
      assert_not agent.paused?
      assert_not agent.scheduled_wakes_enabled?
      assert_equal "external", agent.runtime
      assert Agents::RemoteRuntime.enrollment_for(agent)
      assert_equal 1, @client.creates.size
    end
  end

  test "an archive activation that fails stays inactive with its stage kept, and cleanup frees the slot" do
    with_house do
      agent = staged_import!
      Agents::VmBirthPolicy.current.admit_import!(placement: agent.placement, requested_by: @user)
      @client.on_create = ->(_) { raise HetznerCloudClient::Error.new("no capacity", status: 412, code: "resource_unavailable") }
      assert_enqueued_with(job: VmCleanupJob) { run_job(agent) }
      assert_match(/\AActivation on its own server failed: /, agent.sandbox_last_error)
      assert_not agent.active?
      assert agent.paused?
      assert_equal "offline", agent.runtime
      assert_equal 3, agent.import_stages.count
      VmCleanupJob.perform_now(agent.placement.id)
      assert_equal "retired", agent.placement.reload.state
      assert_equal 0, Agents::VmBirthPolicy.current.vm_count
    end
  end

  test "an archive activation on a runner that cannot seed roles fails plainly and seeds nothing" do
    with_house do
      agent = staged_import!
      Agents::VmBirthPolicy.current.admit_import!(placement: agent.placement, requested_by: @user)
      run_job(agent)
      boot_and_enroll!(agent)
      assert_enqueued_with(job: VmCleanupJob) { run_job(agent) }
      assert_match(/newer runner/, agent.sandbox_last_error)
      assert_equal 0, RunnerCommand.where(agent_placement_id: agent.placement.id, kind: "seed_home").count
      assert_not agent.active?
      assert_equal 3, agent.import_stages.count
    end
  end

  # Seeds every role of the current generation and answers them done.
  def seed_all!(placement)
    seeds = RunnerCommand.where(agent_placement_id: placement.id, kind: "seed_home", generation: placement.reload.generation).order(:id)
    assert_equal %w[identity repo work], seeds.map(&:seed_role)
    seeds.each { |command| command.deliver!(now: Time.current); command.record_result!({ "outcome" => "done" }, now: Time.current) }
    seeds
  end

  def roles_enrolled!(agent)
    operation(agent).runner_enrollment.update!(last_facts: { "seed_roles" => AgentImportStage::ROLES })
  end

  test "past its deadline an activation fails and releases its server; Activate again buys one new server and finishes" do
    with_house do
      agent = staged_import!
      placement = agent.placement
      policy = Agents::VmBirthPolicy.current
      policy.admit_import!(placement:, requested_by: @user)
      run_job(agent)
      boot_and_enroll!(agent)
      roles_enrolled!(agent)
      run_job(agent)
      first_seeds = seed_all!(placement)
      staged_digests = agent.import_stages.order(:role).pluck(:role, :sha256)

      travel 46.minutes do
        assert_enqueued_with(job: VmCleanupJob) { run_job(agent) }
        assert_match(/\AActivation on its own server failed: .*deadline/, agent.sandbox_last_error)
        assert_equal "failed", placement.reload.state
        assert_not agent.active?
        assert agent.paused?

        # Its server is not yet confirmed gone: the retry is refused, nothing bought.
        error = assert_raises(Agents::VmBirthPolicy::Refused) { policy.admit_import!(placement:, requested_by: @user) }
        assert_equal Agents::VmBirthPolicy::STILL_RELEASING, error.message
        assert_equal 1, @client.creates.size
        assert_equal 1, policy.vm_count, "the slot is held until deletion is confirmed"

        VmCleanupJob.perform_now(placement.id)
        assert_equal [ [ 4242, placement.id.to_s ] ], @client.deletes
        assert_equal "deleted", operation(agent).state
        assert_equal "retired", placement.reload.state
        assert_equal 0, policy.vm_count
        assert_equal 3, agent.reload.import_stages.count, "the staged homes outlive the server"

        serve_creates_as(4343)
        policy.admit_import!(placement:, requested_by: @user)
        placement.reload
        assert_equal "pending", placement.state
        assert_equal 2, placement.generation
        assert_nil placement.cleanup_requested_at
        assert_nil placement.first_backup_command_id
        assert_in_delta 45.minutes.from_now, placement.birth_deadline_at, 5
        assert_equal 1, policy.vm_count
        error = assert_raises(Agents::VmBirthPolicy::Refused) { policy.admit_import!(placement:, requested_by: @user) }
        assert_equal Agents::VmBirthPolicy::ALREADY_ACTIVATING, error.message, "a second Activate on the retry buys nothing"

        run_job(agent)
        assert_equal 2, @client.creates.size, "one new server for the new attempt"
        run_job(agent)
        assert_equal 2, @client.creates.size, "never a second order for it"
        assert_equal 2, operation(agent).placement_generation
        boot_and_enroll!(agent)
        roles_enrolled!(agent)
        run_job(agent)
        second_seeds = seed_all!(placement)
        assert_equal staged_digests, agent.reload.import_stages.order(:role).pluck(:role, :sha256),
          "the retry seeds the same staged bytes"
        assert_equal first_seeds.size, second_seeds.size

        run_job(agent)
        assert_equal "ready", placement.reload.state
        answer_latest(placement, "start_resident")
        run_job(agent)
        assert_nil agent.runtime_ready_at, "no turn before the first verified backup"
        assert_nil Agents::RemoteRuntime.enrollment_for(agent)
        @backups.state = "verified"
        assert_no_enqueued_jobs(only: OrientNewAgentJob) { run_job(agent) }
        assert agent.runtime_ready_at
        assert agent.active?
        assert_not agent.scheduled_wakes_enabled?
        assert_nil agent.sandbox_last_error
        assert_equal [ 1, 2 ], placement.cloud_procurement_operations.order(:id).pluck(:placement_generation)
        assert_equal %w[deleted provisioned], placement.cloud_procurement_operations.order(:id).pluck(:state)
      end
    end
  end

  test "a retry waits for a backup hold left by the failed attempt to be released" do
    with_house do
      agent = staged_import!
      placement = agent.placement
      policy = Agents::VmBirthPolicy.current
      policy.admit_import!(placement:, requested_by: @user)
      @client.on_create = ->(_) { raise HetznerCloudClient::Error.new("no capacity", status: 412, code: "resource_unavailable") }
      run_job(agent)
      VmCleanupJob.perform_now(placement.id)
      assert_equal "retired", placement.reload.state

      held = Object.new
      held.define_singleton_method(:exists?) { |agent_id:| agent_id == agent.id }
      VmBackup.stub(:holding, held) do
        error = assert_raises(Agents::VmBirthPolicy::Refused) { policy.admit_import!(placement:, requested_by: @user) }
        assert_equal Agents::VmBirthPolicy::STILL_RELEASING, error.message
      end
      assert_equal "retired", placement.reload.state
      assert_equal 1, placement.generation

      policy.admit_import!(placement:, requested_by: @user)
      assert_equal 2, placement.reload.generation
    end
  end

  test "a retry is capped like any admission and stays retryable when refused" do
    with_house do
      agent = staged_import!
      placement = agent.placement
      policy = Agents::VmBirthPolicy.current
      policy.admit_import!(placement:, requested_by: @user)
      @client.on_create = ->(_) { raise HetznerCloudClient::Error.new("no capacity", status: 412, code: "resource_unavailable") }
      run_job(agent)
      VmCleanupJob.perform_now(placement.id)

      @setting.update!(vm_resident_limit: 1)
      born!
      error = assert_raises(Agents::VmBirthPolicy::Refused) { policy.admit_import!(placement:, requested_by: @user) }
      assert_equal Agents::VmBirthPolicy::LIMIT_REFUSAL, error.message
      assert_equal "retired", placement.reload.state
      assert_equal 1, placement.generation
      assert placement.cleanup_requested?, "nothing about the failed attempt is reset by a refused retry"

      @setting.update!(vm_resident_limit: 2)
      @setting.update!(new_residents_on_vm: false)
      error = assert_raises(Agents::VmBirthPolicy::Refused) { policy.admit_import!(placement:, requested_by: @user) }
      assert_equal Agents::VmBirthPolicy::IMPORT_SWITCHED_OFF, error.message
      assert_equal "retired", placement.reload.state
    end
  end

  test "a ready import is never failed or cleaned up by its deadline, and a late run does nothing" do
    with_house do
      agent = staged_import!
      placement = agent.placement
      Agents::VmBirthPolicy.current.admit_import!(placement:, requested_by: @user)
      run_job(agent)
      boot_and_enroll!(agent)
      roles_enrolled!(agent)
      run_job(agent)
      seed_all!(placement)
      run_job(agent)
      answer_latest(placement, "start_resident")
      run_job(agent)
      @backups.state = "verified"
      run_job(agent)
      assert agent.runtime_ready_at

      travel 46.minutes do
        assert_no_enqueued_jobs(only: VmCleanupJob) { run_job(agent) }
        assert_equal "ready", placement.reload.state
        assert_not placement.cleanup_requested?
        assert agent.active?
        error = assert_raises(Agents::VmBirthPolicy::Refused) do
          Agents::VmBirthPolicy.current.admit_import!(placement:, requested_by: @user)
        end
        assert_equal Agents::VmBirthPolicy::ALREADY_ACTIVATING, error.message
      end
      assert_equal 1, @client.creates.size
      assert_empty @client.deletes
    end
  end

  test "a runner command from the failed attempt never counts for the retry" do
    with_house do
      agent = staged_import!
      placement = agent.placement
      policy = Agents::VmBirthPolicy.current
      policy.admit_import!(placement:, requested_by: @user)
      run_job(agent)
      boot_and_enroll!(agent)
      roles_enrolled!(agent)
      run_job(agent)
      old_seeds = RunnerCommand.where(agent_placement_id: placement.id, kind: "seed_home").to_a
      travel 46.minutes do
        run_job(agent)
        VmCleanupJob.perform_now(placement.id)
        VmCleanupJob.perform_now(placement.id)
        serve_creates_as(4343)
        policy.admit_import!(placement:, requested_by: @user)

        # The old attempt's seeds: one answered late as done, one left
        # delivered, one unknown. None is this attempt's, and none blocks it.
        old_seeds[0].update_columns(state: "done", finished_at: Time.current)
        old_seeds[1].update_columns(state: "delivered", delivered_at: Time.current)
        old_seeds[2].update_columns(state: "unknown", finished_at: Time.current)
        assert Agents::VmSeed.new(agent.reload).status.none?
        run_job(agent)
        boot_and_enroll!(agent)
        roles_enrolled!(agent)
        run_job(agent)
        assert_equal 3, RunnerCommand.where(agent_placement_id: placement.id, kind: "seed_home", generation: 2).count
        assert_not Agents::VmSeed.new(agent.reload).status.done?
        assert Backup::VmResident.busy?(agent), "this attempt's own queued seeds block a backup"

        seed_all!(placement)
        run_job(agent)
        answer_latest(placement, "start_resident")
        assert_not Backup::VmResident.busy?(agent),
          "the failed attempt's delivered and unknown seeds never block the retry's first backup"
      end
    end
  end

  test "admission at Activate re-checks the switch and the cap under the lock and refuses a second Activate" do
    with_house do
      agent = staged_import!
      policy = Agents::VmBirthPolicy.current

      @setting.update!(new_residents_on_vm: false)
      error = assert_raises(Agents::VmBirthPolicy::Refused) { policy.admit_import!(placement: agent.placement, requested_by: @user) }
      assert_equal Agents::VmBirthPolicy::IMPORT_SWITCHED_OFF, error.message
      assert agent.placement.reload.staged?

      @setting.update!(new_residents_on_vm: true, vm_resident_limit: 1)
      born!
      error = assert_raises(Agents::VmBirthPolicy::Refused) { policy.admit_import!(placement: agent.placement, requested_by: @user) }
      assert_equal Agents::VmBirthPolicy::LIMIT_REFUSAL, error.message
      assert agent.placement.reload.staged?

      @setting.update!(vm_resident_limit: 2)
      policy.admit_import!(placement: agent.placement, requested_by: @user)
      error = assert_raises(Agents::VmBirthPolicy::Refused) { policy.admit_import!(placement: agent.placement, requested_by: @user) }
      assert_equal Agents::VmBirthPolicy::ALREADY_ACTIVATING, error.message
      assert_equal 2, policy.vm_count
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

  test "admission is capped under the lock, and a resident on an API-key model is born on a VM too" do
    with_house do
      @setting.update!(vm_resident_limit: 1)
      born!
      HouseInferenceGrant.where(user: @user).update_all(agent_id: nil)
      error = assert_raises(Agents::VmBirthPolicy::Refused) { born! }
      assert_equal Agents::VmBirthPolicy::LIMIT_REFUSAL, error.message

      @setting.update!(vm_resident_limit: 5)
      agent = born!(model_id: "openrouter/auto", name: "Vm born on a key")
      assert agent.placement.vm_birth?
      assert_equal "hetzner_cloud", agent.placement.backend
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


  # --- GitHub imports on their own VM (docs/2026-10-10-vm-imports.md, points 4, 5, 8) ---

  # A reviewed checkout on disk, as GithubImportSource#with_checkout yields it.
  def reviewed_checkout
    root = Dir.mktmpdir("reviewed-home-")
    FileUtils.mkdir_p(File.join(root, "memory"))
    File.write(File.join(root, "soul.md"), "I am imported.\n")
    File.write(File.join(root, "memory", "index.md"), "- first\n")
    root
  end

  def github_source(request, root)
    source = Object.new
    source.define_singleton_method(:with_checkout) do |branch:, commit_sha: nil, &block|
      block.call(root, { "identity_id" => request.portable_home_id }, commit_sha || "a" * 40, branch.presence || "main")
    end
    source
  end

  def run_import(request, root)
    Agents::GithubImportSource.stub(:new, github_source(request, root)) do
      Agents::Volume.stub(:new, ->(*) { flunk "a GitHub import on its own server never touches a house volume" }) do
        Agents::Sandbox.stub(:new, ->(*) { flunk "a GitHub import on its own server never reaches the house sandbox" }) do
          GithubResidentImportJob.perform_now(request.id)
        end
      end
    end
    request.reload
  end

  def approved_import
    request = import_request
    approve_fixture(request)
    request
  end

  def trust_enrolled!(agent)
    operation(agent).runner_enrollment.update!(last_facts: { "runtime_trust_check" => Agents::RemoteRuntime::RUNTIME_TRUST_CHECK_VERSION })
  end

  def answer_trust(placement, trust)
    command = RunnerCommand.where(agent_placement_id: placement.id, kind: "check_runtime_trust").order(:id).last
    command.deliver!(now: Time.current)
    command.record_result!({ "outcome" => "done", "result" => { "trust" => trust } }, now: Time.current)
    command
  end

  def trust_checks(placement) = RunnerCommand.where(agent_placement_id: placement.id, kind: "check_runtime_trust")

  # Imported, admitted, ordered, enrolled and seeded: up to its first trust check.
  def github_import_seeded!(request = approved_import)
    root = reviewed_checkout
    assert_enqueued_with(job: ProvisionVmAgentJob) { run_import(request, root) }
    agent = request.agent
    run_job(agent)
    boot_and_enroll!(agent)
    trust_enrolled!(agent)
    run_job(agent)
    seed = RunnerCommand.where(agent_placement_id: agent.placement.id, kind: "seed_home").sole
    assert_nil seed.seed_role, "a GitHub import seeds identity only, with a birth's payload"
    assert_equal agent.import_stages.sole.sha256, JSON.parse(seed.payload_json)["sha256"]
    seed.deliver!(now: Time.current)
    seed.record_result!({ "outcome" => "done" }, now: Time.current)
    [ request, agent.reload ]
  end

  test "a GitHub import on its own VM: admitted at import, seeded from the reviewed checkout, trust-gated, then ready" do
    with_house do
      request = approved_import
      root = reviewed_checkout
      assert_difference("Agent.count", 1) do
        assert_enqueued_with(job: ProvisionVmAgentJob) { run_import(request, root) }
      end
      agent = request.agent
      placement = agent.placement
      assert_equal "provisioning", request.status
      assert_equal "github_import", placement.kind
      assert_equal "pending", placement.state
      assert placement.vm_birth?
      assert_equal @user, placement.birth_requested_by
      assert_equal %w[identity], agent.import_stages.pluck(:role)
      assert_not agent.active?
      assert agent.paused?
      assert_equal 1, Agents::VmBirthPolicy.current.vm_count

      run_job(agent)
      assert_equal 1, @client.creates.size, "bought at import"
      boot_and_enroll!(agent)
      trust_enrolled!(agent)
      run_job(agent)
      answer_latest(placement, "seed_home")

      run_job(agent)
      assert_equal 1, trust_checks(placement).count
      assert_equal 0, RunnerCommand.where(agent_placement_id: placement.id, kind: "start_resident").count, "nothing starts before trust"
      payload = JSON.parse(trust_checks(placement).last.payload_json)
      assert_equal Agents::ImportedHomeEnv.trust_check(agent), payload["env"]

      answer_trust(placement, "untrusted")
      run_job(agent)
      assert_equal "needs_runtime_trust", request.reload.status
      assert_not agent.reload.active?
      assert agent.paused?
      assert_equal "pending", placement.reload.state
      run_job(agent)
      assert_equal 1, trust_checks(placement).count, "an untrusted home waits; it is not asked again on its own"
      assert_equal 0, RunnerCommand.where(agent_placement_id: placement.id, kind: "start_resident").count

      # The operator grants trust on Chaos's own screen on that server, then retries.
      assert_enqueued_with(job: GithubResidentImportJob) { request.retry_activation!(@user) }
      assert_enqueued_with(job: ProvisionVmAgentJob) { run_import(request, root) }
      assert_equal 2, trust_checks(placement).count, "a retry asks again"
      answer_trust(placement, "trusted")

      run_job(agent)
      assert_equal "ready", placement.reload.state
      start = RunnerCommand.where(agent_placement_id: placement.id, kind: "start_resident").sole
      env = JSON.parse(start.payload_json)["env"]
      assert_equal request.id.to_s, env["SOULSHOUSE_GITHUB_IMPORT_ID"]
      assert_equal "portable_v1", env["SOULSHOUSE_HOME_PROFILE"]
      answer_latest(placement, "start_resident")
      run_job(agent)
      assert_nil agent.reload.runtime_ready_at, "no turn before the first verified backup"
      assert_nil Agents::RemoteRuntime.enrollment_for(agent)
      @backups.state = "verified"
      assert_no_enqueued_jobs(only: OrientNewAgentJob) { run_job(agent) }
      assert agent.runtime_ready_at
      assert agent.active?
      assert_not agent.paused?
      assert_not agent.scheduled_wakes_enabled?
      assert agent.identity_seeded_at
      assert_equal "ready", request.reload.status
      assert_equal 1, @client.creates.size
      assert_equal [ request.service_connection_id ], agent.agent_service_accesses.pluck(:service_connection_id)
    end
  end

  test "waiting for trust past the deadline releases the server, keeps the home and the retry, and the retry buys one new server" do
    with_house do
      request, agent = github_import_seeded!
      placement = agent.placement
      run_job(agent)
      answer_trust(placement, "untrusted")
      run_job(agent)
      assert_equal "needs_runtime_trust", request.reload.status
      staged = agent.import_stages.pluck(:sha256)

      travel 46.minutes do
        assert_enqueued_with(job: VmCleanupJob) { run_job(agent) }
        assert_equal "needs_runtime_trust", request.reload.status, "a person taking longer than 45 minutes is not a failed import"
        assert_equal ProvisionVmAgentJob::TRUST_RELEASED, request.last_error
        assert_equal "failed", placement.reload.state
        assert_equal staged, agent.reload.import_stages.pluck(:sha256), "the reviewed home is never discarded"
        assert_not agent.active?
        VmCleanupJob.perform_now(placement.id)
        assert_equal "retired", placement.reload.state
        assert_equal 0, Agents::VmBirthPolicy.current.vm_count

        serve_creates_as(4343)
        request.retry_activation!(@user)
        assert_enqueued_with(job: ProvisionVmAgentJob) { run_import(request, reviewed_checkout) }
        assert_equal "pending", placement.reload.state
        assert_equal 2, placement.generation
        assert_equal "provisioning", request.reload.status
        run_job(agent)
        assert_equal 2, @client.creates.size, "one new server for the retry"
        boot_and_enroll!(agent)
        trust_enrolled!(agent)
        run_job(agent)
        seed = RunnerCommand.where(agent_placement_id: placement.id, kind: "seed_home", generation: 2).sole
        assert_equal staged.first, JSON.parse(seed.payload_json)["sha256"], "the same reviewed bytes"
        seed.deliver!(now: Time.current)
        seed.record_result!({ "outcome" => "done" }, now: Time.current)
        run_job(agent)
        assert_equal 1, trust_checks(placement).where(generation: 2).count, "the new server is checked afresh"
      end
    end
  end

  test "a retry while the released server is still being deleted is refused plainly and buys nothing" do
    with_house do
      request, agent = github_import_seeded!
      run_job(agent)
      answer_trust(agent.placement, "untrusted")
      run_job(agent)
      travel 46.minutes do
        run_job(agent)
        request.retry_activation!(@user)
        run_import(request, reviewed_checkout)
        assert_equal "failed", request.status
        assert_equal Agents::VmBirthPolicy::STILL_RELEASING, request.last_error
        assert_equal 1, @client.creates.size
      end
    end
  end

  test "an image without the managed-import runtime fails plainly and never starts" do
    with_house do
      request, agent = github_import_seeded!
      run_job(agent)
      answer_trust(agent.placement, "unsupported")
      assert_enqueued_with(job: VmCleanupJob) { run_job(agent) }
      assert_equal "failed", request.reload.status
      assert_match(/does not support managed GitHub imports/, request.last_error)
      assert_equal 0, RunnerCommand.where(agent_placement_id: agent.placement.id, kind: "start_resident").count
      assert_not agent.reload.active?
    end
  end

  test "a runner without the trust check gets none and the start fails plainly" do
    with_house do
      request = approved_import
      run_import(request, reviewed_checkout)
      agent = request.agent
      run_job(agent)
      boot_and_enroll!(agent)
      run_job(agent)
      answer_latest(agent.placement, "seed_home")
      assert_enqueued_with(job: VmCleanupJob) { run_job(agent) }
      assert_equal 0, trust_checks(agent.placement).count
      assert_match(/newer runner/, request.reload.last_error)
      assert_equal "failed", request.status
      assert_equal 0, RunnerCommand.where(agent_placement_id: agent.placement.id, kind: "start_resident").count
    end
  end

  test "trust checks that keep failing fail the start; a failed one is asked again first" do
    with_house do
      request, agent = github_import_seeded!
      placement = agent.placement
      run_job(agent)
      2.times do
        command = trust_checks(placement).order(:id).last
        command.deliver!(now: Time.current)
        command.record_result!({ "outcome" => "failed", "error" => "docker went away" }, now: Time.current)
        run_job(agent)
      end
      assert_equal 3, trust_checks(placement).count
      command = trust_checks(placement).order(:id).last
      command.deliver!(now: Time.current)
      command.record_result!({ "outcome" => "unknown" }, now: Time.current)
      assert_enqueued_with(job: VmCleanupJob) { run_job(agent) }
      assert_equal "failed", request.reload.status
      assert_equal 0, RunnerCommand.where(agent_placement_id: placement.id, kind: "start_resident").count
    end
  end

  test "an import the cap can't admit fails with the reason and leaves nothing" do
    with_house do
      @setting.update!(vm_resident_limit: 1)
      born!
      request = approved_import
      assert_no_difference [ "Agent.count", "AgentPlacement.count", "AgentImportStage.count" ] do
        assert_no_enqueued_jobs(only: ProvisionVmAgentJob) { run_import(request, reviewed_checkout) }
      end
      assert_equal "failed", request.status
      assert_equal Agents::VmBirthPolicy::LIMIT_REFUSAL, request.last_error
    end
  end

  test "switched off after admission, an import stays on its own server and is never made on the house" do
    with_house do
      request, agent = github_import_seeded!
      @setting.update!(new_residents_on_vm: false)
      run_job(agent)
      answer_trust(agent.placement, "untrusted")
      run_job(agent)
      request.retry_activation!(@user)
      assert_enqueued_with(job: ProvisionVmAgentJob) { run_import(request, reviewed_checkout) }
      assert_equal 2, trust_checks(agent.placement).count
      assert_equal "github_import", agent.reload.placement.kind
    end
  end

  test "an import whose approval changed while waiting is not started" do
    with_house do
      request, agent = github_import_seeded!
      run_job(agent)
      request.update_columns(approved_commit_sha: "b" * 40)
      answer_trust(agent.placement, "trusted")
      run_job(agent)
      assert_equal 0, RunnerCommand.where(agent_placement_id: agent.placement.id, kind: "start_resident").count
      assert_not agent.reload.active?
    end
  end


  test "admission refusing after the checkout leaves no resident, and a later approval is admitted again, never on the house" do
    with_house do
      @setting.update!(vm_resident_limit: 1)
      request = approved_import
      root = reviewed_checkout
      source = Object.new
      test = self
      source.define_singleton_method(:with_checkout) do |branch:, commit_sha: nil, &block|
        test.born! # the last slot is taken while the repository is fetched
        block.call(root, { "identity_id" => request.portable_home_id }, commit_sha || "a" * 40, branch.presence || "main")
      end
      Agents::GithubImportSource.stub(:new, source) do
        Agents::Volume.stub(:new, ->(*) { flunk "never a house volume" }) do
          assert_no_difference "AgentImportStage.count" do
            GithubResidentImportJob.perform_now(request.id)
          end
        end
      end
      request.reload
      assert_equal "failed", request.status
      assert_equal Agents::VmBirthPolicy::LIMIT_REFUSAL, request.last_error
      assert_nil request.agent, "a refused admission never leaves a resident behind to be autosaved"
      assert_nil Agent.find_by(github_resident_import_id: request.id)

      @setting.update!(vm_resident_limit: 2)
      approve_fixture(request)
      run_import(request, root)
      assert_equal "github_import", request.agent.placement.kind, "admitted to its own server, not made on the house"
    end
  end

  test "a failure while staging rolls the whole admission back and leaves nothing" do
    with_house do
      request = approved_import
      Agents::GithubImportStage.stub(:persist!, ->(*) { raise ActiveRecord::RecordInvalid, AgentImportStage.new }) do
        assert_raises(ActiveRecord::RecordInvalid) { run_import(request, reviewed_checkout) }
      end
      assert_nil Agent.find_by(github_resident_import_id: request.id)
      assert_equal 0, AgentPlacement.where(kind: "github_import").count
      assert_equal "failed", request.reload.status
    end
  end

  test "a reviewed home holding the runner's seed marker is refused before admission" do
    with_house do
      request = approved_import
      root = reviewed_checkout
      File.write(File.join(root, ".souls-house-seed"), "a reviewed file")
      run_import(request, root)
      assert_equal "failed", request.status
      assert_match(/seed reserves/, request.last_error)
      assert_nil Agent.find_by(github_resident_import_id: request.id)
      assert_empty @client.creates
    end
  end

  # Brought all the way to ready.
  def github_import_ready!
    request, agent = github_import_seeded!
    placement = agent.placement
    run_job(agent)
    answer_trust(placement, "trusted")
    run_job(agent)
    answer_latest(placement, "start_resident")
    run_job(agent)
    @backups.state = "verified"
    run_job(agent)
    assert agent.reload.runtime_ready_at
    assert_equal "ready", request.reload.status
    [ request, agent ]
  end

  test "approved again when ready, it is trust-checked, then refreshed between turns, then ready again" do
    with_house do
      request, agent = github_import_ready!
      placement = agent.placement
      starts = -> { RunnerCommand.where(agent_placement_id: placement.id, kind: "start_resident").count }
      assert_equal 1, starts.call
      request.update!(status: "pending_review")
      approve_fixture(request)
      assert_enqueued_with(job: ProvisionVmAgentJob) { run_import(request, reviewed_checkout) }
      assert_equal "provisioning", request.status
      assert_equal 2, trust_checks(placement).count, "re-approval checks trust again, as on the house"

      run_job(agent)
      assert_equal 1, starts.call, "no refresh before the check answers"
      answer_trust(placement, "trusted")
      assert_enqueued_with(job: RemoteRefreshSettleJob) { run_job(agent) }
      assert_equal 2, starts.call, "the approved values reach its server through the credential/service restart"
      assert placement.reload.refresh_command_id
      assert_equal "provisioning", request.reload.status, "not ready until the restart is confirmed"
      run_job(agent)
      assert_equal "provisioning", request.reload.status

      answer_refresh(placement)
      run_job(agent)
      assert_nil placement.reload.refresh_command_id
      assert_equal "ready", request.reload.status
      assert agent.reload.active?
      assert_equal "ready", placement.state
      assert_equal 2, starts.call
      assert_empty @client.deletes

      assert_no_enqueued_jobs(only: ProvisionVmAgentJob) { VmBirthSweepJob.perform_now }
      run_job(agent)
      assert_equal 2, starts.call, "no second refresh after settlement"
    end
  end

  test "approved again when ready, a restart the runner never answers fails the request once its answer window passes" do
    with_house do
      request, agent = github_import_ready!
      placement = agent.placement
      request.update!(status: "pending_review")
      approve_fixture(request)
      run_import(request, reviewed_checkout)
      answer_trust(placement, "trusted")
      run_job(agent)
      run_job(agent)
      assert_equal "provisioning", request.reload.status, "pending while the runner may still answer"
      travel Agents::RemoteRuntime::REFRESH_ANSWER_WITHIN + 1.minute do
        run_job(agent)
        assert_equal "failed", request.reload.status
        assert_match(/did not settle: .*no answer/, request.last_error)
        assert placement.reload.refresh_command_id, "turns stay held"
        assert_equal "ready", placement.state
        assert_empty @client.deletes
      end
    end
  end

  def answer_refresh(placement, image: IMAGE, outcome: "done")
    command = RunnerCommand.find(placement.reload.refresh_command_id)
    command.deliver!(now: Time.current)
    command.record_result!({ "outcome" => outcome, "result" => { "image" => image } }, now: Time.current)
  end

  test "approved again when ready, a restart that never settles fails the request plainly and keeps turns held" do
    with_house do
      request, agent = github_import_ready!
      placement = agent.placement
      request.update!(status: "pending_review")
      approve_fixture(request)
      run_import(request, reviewed_checkout)
      answer_trust(placement, "trusted")
      run_job(agent)
      answer_refresh(placement, outcome: "failed")
      run_job(agent) # one recovery start
      assert_equal "provisioning", request.reload.status
      answer_refresh(placement, outcome: "failed")
      run_job(agent)
      assert_equal "failed", request.reload.status
      assert_match(/did not settle/, request.last_error)
      assert placement.reload.refresh_command_id, "turns stay held until an operator releases the hold"
      assert_empty @client.deletes
    end
  end

  test "approved again when ready and not trusted, it waits paused with its server; nothing is cleaned up" do
    with_house do
      request, agent = github_import_ready!
      placement = agent.placement
      request.update!(status: "pending_review")
      approve_fixture(request)
      run_import(request, reviewed_checkout)
      answer_trust(placement, "untrusted")
      assert_no_enqueued_jobs(only: VmCleanupJob) { run_job(agent) }
      assert_equal "needs_runtime_trust", request.reload.status
      assert agent.reload.paused?
      assert_not agent.active?
      assert_equal "ready", placement.reload.state
      assert_not placement.cleanup_requested?

      travel 2.hours do
        assert_no_enqueued_jobs(only: VmCleanupJob) { run_job(agent) }
        assert_equal "ready", placement.reload.state, "a ready resident's server is never released by the birth deadline"
      end
    end
  end

  test "a refresh refused as busy is tried again by the sweep" do
    with_house do
      request, agent = github_import_ready!
      placement = agent.placement
      request.update!(status: "pending_review")
      approve_fixture(request)
      run_import(request, reviewed_checkout)
      answer_trust(placement, "trusted")
      Agents::RemoteRuntime.stub(:begin_refresh!, :busy) { run_job(agent) }
      assert_equal "provisioning", request.reload.status
      assert_nil placement.reload.refresh_command_id
      assert_enqueued_with(job: ProvisionVmAgentJob, args: [ agent.id ]) { VmBirthSweepJob.perform_now }
      run_job(agent)
      answer_refresh(placement)
      run_job(agent)
      assert_equal "ready", request.reload.status
    end
  end

  # #426, slice 3A: an existing house resident moving to its own server.

  # A stopped house resident's three volumes, as Portability::Transport
  # captures them.
  class HouseTransport

    def stopped! = true

    def capture(root, output)
      Gem::Package::TarWriter.new(output) do |tar|
        tar.mkdir(".", 0755)
        files = { "#{root}.md" => "#{root} as lived on the house" }
        files["soul.md"] = "A soul with days behind it" if root == "identity"
        files.each { |name, body| tar.add_file_simple("./#{name}", 0644, body.bytesize) { |file| file.write(body) } }
      end
    end

  end

  # A resident that has been running on the house since lived_since, then
  # stopped through Portability (inactive, paused, offline).
  def house_resident!(name: "House resident", lived_since: 3.days.ago.change(usec: 0), scheduled_wakes_enabled: true)
    agent = @account.agents.create!(name:, model_id: HouseInference::Offering::OFFERINGS.keys.first, runtime: "offline",
      active: false, paused: true, scheduled_wakes_enabled:, home_profile: "house", uuid: SecureRandom.uuid_v7)
    agent.update_columns(runtime_ready_at: lived_since, identity_seeded_at: lived_since)
    agent.reload
  end

  def migration(agent) = Agents::VmMigration.new(agent)

  def stage_move!(agent)
    Agents::Config.stub(:internal_url, "http://synthetic.invalid") do
      migration(agent).stage!(requested_by: @user, transport: HouseTransport.new)
    end
  end

  test "a move is refused, with nothing changed, unless the house can make servers and the resident is stopped" do
    with_house do
      agent = house_resident!
      @setting.update!(new_residents_on_vm: false)
      assert_equal Agents::VmMigration::SWITCHED_OFF, migration(agent).refusal
      @setting.update!(new_residents_on_vm: true, vm_resident_limit: 0)
      assert_equal Agents::VmMigration::AT_LIMIT, migration(agent).refusal
      @setting.update!(vm_resident_limit: 2)

      agent.update_columns(active: true, paused: false)
      assert_match(/inactive, paused/, migration(agent).refusal)
      error = assert_raises(Agents::VmMigration::Refused) { stage_move!(agent) }
      assert_match(/inactive, paused/, error.message)
      agent.update_columns(active: false, paused: true)

      never = house_resident!(name: "Never ran")
      never.update_columns(runtime_ready_at: nil)
      assert_equal Agents::VmMigration::NEVER_LIVED, migration(never).refusal

      assert_nil agent.reload.placement
      assert_empty agent.import_stages
      assert agent.runtime_ready_at
    end
  end

  test "staging copies the stopped home into three stages, moves runtime_ready_at aside, and nothing can run it" do
    with_house do
      lived_since = 3.days.ago.change(usec: 0)
      agent = house_resident!(lived_since:)
      placement = stage_move!(agent)
      agent.reload

      assert_equal %w[hetzner_cloud migration staged], [ placement.backend, placement.kind, placement.state ]
      assert_equal lived_since, placement.house_runtime_ready_at
      assert_nil agent.runtime_ready_at
      assert_equal %w[identity repo work], agent.import_stages.order(:role).pluck(:role)
      identity = Zlib::GzipReader.wrap(StringIO.new(agent.import_stages.find_by(role: "identity").archive)) do |gz|
        Gem::Package::TarReader.new(gz).each.to_h { |entry| [ entry.full_name, entry.file? ? entry.read : nil ] }
      end
      assert_equal "identity as lived on the house", identity["identity.md"]
      assert_not Agents::RuntimeLocation.local?(agent), "the house never runs a resident staged to move"
      assert_not Agents::RuntimeLocation.dispatchable?(agent)
      assert_equal 0, Agents::VmBirthPolicy.current.vm_count, "staging buys nothing and takes no slot"
      assert AuditLog.exists?(action: "vm_migration_staged", auditable: agent)

      assert_equal Agents::VmMigration::ALREADY_PLACED, migration(agent).refusal
      run_job(agent)
      assert_empty @client.creates
    end
  end

  test "a whole move: seeded per role, no turn before its verified backup, then running with nothing reset" do
    with_house do
      agent = house_resident!(scheduled_wakes_enabled: true)
      placement = stage_move!(agent)
      migration(agent.reload).activate!(requested_by: @user)
      assert_equal "pending", placement.reload.state
      assert_equal 1, Agents::VmBirthPolicy.current.vm_count

      run_job(agent)
      boot_and_enroll!(agent)
      roles_enrolled!(agent)
      run_job(agent)
      seed_all!(placement)
      run_job(agent)
      assert_equal "ready", placement.reload.state
      answer_latest(placement, "start_resident")
      run_job(agent)
      run_job(agent)
      assert_nil Agents::RemoteRuntime.enrollment_for(agent.reload), "ready and started, but not yet backed up: no turn"
      assert agent.paused?

      @backups.state = "verified"
      assert_no_enqueued_jobs(only: OrientNewAgentJob) { run_job(agent) }
      assert agent.runtime_ready_at
      assert agent.active?
      assert_not agent.paused?
      assert agent.scheduled_wakes_enabled?, "its own schedule choice is kept"
      assert_equal 3.days.ago.to_date, agent.identity_seeded_at.to_date, "not re-seeded as new"
      assert Agents::RemoteRuntime.enrollment_for(agent)
      assert AuditLog.exists?(action: "vm_migration_ready", auditable: agent)
      error = assert_raises(Agents::VmMigration::Refused) { migration(agent).return_to_house!(requested_by: @user) }
      assert_equal Agents::VmMigration::CUT_OVER, error.message
    end
  end

  test "a failed move stays paused, can't go back until its server is gone, then returns to the house as it was" do
    with_house do
      lived_since = 3.days.ago.change(usec: 0)
      agent = house_resident!(lived_since:)
      placement = stage_move!(agent)
      migration(agent.reload).activate!(requested_by: @user)
      @client.on_create = ->(_) { raise HetznerCloudClient::Error.new("no capacity", status: 412, code: "resource_unavailable") }
      assert_enqueued_with(job: VmCleanupJob) { run_job(agent) }
      assert_match(/\AMoving to its own server failed: .*Its home is still on the house, untouched/, agent.sandbox_last_error)
      assert agent.paused?
      assert_not agent.active?
      assert_nil agent.runtime_ready_at

      error = assert_raises(Agents::VmMigration::Refused) { migration(agent).return_to_house!(requested_by: @user) }
      assert_equal Agents::VmMigration::STILL_RUNNING, error.message
      assert_equal "failed", placement.reload.state

      VmCleanupJob.perform_now(placement.id)
      assert_equal "retired", placement.reload.state
      generation = placement.generation
      migration(agent).return_to_house!(requested_by: @user)
      placement.reload
      agent.reload
      assert_equal [ "local", nil, "ready" ], [ placement.backend, placement.kind, placement.state ]
      assert_equal generation + 1, placement.generation
      assert_nil placement.house_runtime_ready_at
      assert_equal lived_since, agent.runtime_ready_at
      assert_empty agent.import_stages
      assert agent.paused?
      assert Agents::RuntimeLocation.local?(agent)
      assert_equal 0, Agents::VmBirthPolicy.current.vm_count
      assert AuditLog.exists?(action: "vm_migration_returned_to_house", auditable: agent)
      assert_nil migration(agent).refusal, "it can be staged again"
    end
  end

  test "a staged move returns to the house at once, and with the switch off a move stays staged" do
    with_house do
      agent = house_resident!
      stage_move!(agent)
      @setting.update!(new_residents_on_vm: false)
      error = assert_raises(Agents::VmMigration::Refused) { migration(agent.reload).activate!(requested_by: @user) }
      assert_equal Agents::VmBirthPolicy::MIGRATION_SWITCHED_OFF, error.message
      assert_equal "staged", agent.placement.reload.state

      migration(agent).return_to_house!(requested_by: @user)
      assert Agents::RuntimeLocation.local?(agent.reload)
      assert agent.runtime_ready_at
    end
  end

end

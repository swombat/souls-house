require "test_helper"

class Agents::PortabilityControllerTest < ActionDispatch::IntegrationTest

  setup do
    Setting.instance.update!(allow_agents: true)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @agent.update_columns(uuid: SecureRandom.uuid, active: false, paused: true, runtime: "offline")
    post login_path, params: { email_address: users(:user_1).email_address, password: "password123" }
  end

  test "owner import page and invalid uploads return content-free errors and no-store" do
    get import_account_agents_path(@account)
    assert_response :success
    assert_equal "agents/import", inertia_component
    assert_equal import_preview_account_agents_path(@account), inertia_shared_props["preview_url"]
    post import_preview_account_agents_path(@account), params: { archive: "PRIVATE malformed value" }
    assert_response :unprocessable_entity
    assert_equal "private, no-store", response.headers["Cache-Control"]
    refute_includes response.body, "PRIVATE"
    assert_no_difference [ "Agent.count", "ApiKey.count" ] do
      post import_archive_account_agents_path(@account), params: { confirmed: "false", name: "Copy" }
    end
    assert_response :unprocessable_entity
  end

  test "pre-resident entry points expose the frontend import prop only to owners" do
    [ account_agents_path(@account), new_account_agent_path(@account) ].each do |path|
      get path
      @inertia_props = nil
      assert_response :success
      assert_equal import_account_agents_path(@account), inertia_shared_props["resident_import_url"]
    end
    users(:user_1).memberships.find_by!(account: @account).update_column(:role, "member")
    [ account_agents_path(@account), new_account_agent_path(@account) ].each do |path|
      get path
      @inertia_props = nil
      assert_response :success
      assert_nil inertia_shared_props["resident_import_url"]
    end
  end

  test "cross-account export cannot reach transport" do
    transport = ->(*) { flunk "No transport before authorization/scoping" }
    Agents::Portability::Transport.stub(:new, transport) do
      get portable_export_account_agent_path(@account, agents(:other_account_agent))
      assert_response :not_found
    end
  end

  test "ordinary non-owner cannot access private import or graph export" do
    membership = users(:user_1).memberships.find_by!(account: @account)
    membership.update_column(:role, "member")
    get import_account_agents_path(@account)
    assert_response :redirect
    post import_preview_account_agents_path(@account)
    assert_response :redirect
    get portable_export_account_agent_path(@account, @agent)
    assert_response :redirect
  end

  test "activation requires confirmation and stopped state and never stops on rejection" do
    stop = ->(*) { flunk "Rejected activation must not stop a runtime" }
    sandbox = Object.new
    sandbox.define_singleton_method(:stop!, &stop)
    Agents::Sandbox.stub(:new, sandbox) do
      post portability_activate_account_agent_path(@account, @agent), params: { confirmed: false }
      assert_response :unprocessable_entity
      transport = Object.new
      transport.define_singleton_method(:stopped!) { raise Agents::Portability::Error, "Unknown runtime state" }
      Agents::Portability::Transport.stub(:new, transport) do
        post portability_activate_account_agent_path(@account, @agent), params: { confirmed: true }
      end
      assert_response :unprocessable_entity
    end
    refute @agent.reload.active?
    assert @agent.paused?
  end

  test "activating a copy staged for its own server admits it and queues its provisioning, never touching anything local" do
    AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", kind: "archive_import", state: "staged")
    policy = Agents::VmBirthPolicy.new(setting: Setting.instance, procurement_config: CloudProcurement::Config.new(image_id: 1, ssh_key_ids: [ 2 ], locations: [ "fsn1" ], rails_url: "https://house.test", runner_commands: true), api_token: "t")
    Setting.instance.update!(new_residents_on_vm: true, vm_resident_limit: 3)
    policy.define_singleton_method(:vm_backups_available?) { true }
    Agents::VmBirthPolicy.stub(:current, policy) do
      Agents::Sandbox.stub(:new, ->(*) { flunk "a staged copy must never reach the local sandbox" }) do
        Agents::Portability::Transport.stub(:new, ->(*) { flunk "a staged copy has no local volumes" }) do
          post portability_activate_account_agent_path(@account, @agent), params: { confirmed: false }
          assert_response :unprocessable_entity
          assert @agent.placement.reload.staged?

          assert_enqueued_with(job: ProvisionVmAgentJob, args: [ @agent.id ]) do
            post portability_activate_account_agent_path(@account, @agent), params: { confirmed: true }
          end
          assert_response :see_other
          post portability_activate_account_agent_path(@account, @agent), params: { confirmed: true }
          assert_response :unprocessable_entity
          assert_equal Agents::VmBirthPolicy::ALREADY_ACTIVATING, response.parsed_body["error"]
        end
      end
    end
    placement = @agent.placement.reload
    assert_equal "pending", placement.state
    assert_equal users(:user_1), placement.birth_requested_by
    assert AuditLog.exists?(action: "vm_import_activation_admitted", auditable: @agent)
    @agent.reload
    refute @agent.active?, "active only once ready"
    assert @agent.paused?
  end

  test "Activate after a failed start is refused while its server is released, then admits the next attempt" do
    placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", kind: "archive_import", state: "failed",
      cleanup_requested_at: 1.minute.ago, cleanup_reason: "birth_failed: the birth did not finish before its deadline")
    policy = Agents::VmBirthPolicy.new(setting: Setting.instance, procurement_config: CloudProcurement::Config.new(image_id: 1, ssh_key_ids: [ 2 ], locations: [ "fsn1" ], rails_url: "https://house.test", runner_commands: true), api_token: "t")
    Setting.instance.update!(new_residents_on_vm: true, vm_resident_limit: 3)
    policy.define_singleton_method(:vm_backups_available?) { true }
    Agents::VmBirthPolicy.stub(:current, policy) do
      Agents::Sandbox.stub(:new, ->(*) { flunk "a retried copy must never reach the local sandbox" }) do
        Agents::Portability::Transport.stub(:new, ->(*) { flunk "a retried copy has no local volumes" }) do
          assert_no_enqueued_jobs(only: ProvisionVmAgentJob) do
            post portability_activate_account_agent_path(@account, @agent), params: { confirmed: true }
          end
          assert_response :unprocessable_entity
          assert_equal Agents::VmBirthPolicy::STILL_RELEASING, response.parsed_body["error"]
          assert_equal "failed", placement.reload.state

          placement.update!(state: "retired") # cleanup confirmed the server gone
          assert_enqueued_with(job: ProvisionVmAgentJob, args: [ @agent.id ]) do
            post portability_activate_account_agent_path(@account, @agent), params: { confirmed: true }
          end
          assert_response :see_other
        end
      end
    end
    placement.reload
    assert_equal "pending", placement.state
    assert_equal 2, placement.generation
    assert_nil placement.cleanup_requested_at
    audit = AuditLog.where(action: "vm_import_activation_admitted", auditable: @agent).last
    assert_equal true, audit.data["retry"]
    assert_equal 2, audit.data["generation"]
    refute @agent.reload.active?, "active only once ready"
  end

  test "with the switch off a staged copy is refused at activation and stays staged" do
    AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", kind: "archive_import", state: "staged")
    Setting.instance.update!(new_residents_on_vm: false)
    Agents::Sandbox.stub(:new, ->(*) { flunk "never local" }) do
      post portability_activate_account_agent_path(@account, @agent), params: { confirmed: true }
    end
    assert_response :unprocessable_entity
    assert_equal Agents::VmBirthPolicy::IMPORT_SWITCHED_OFF, response.parsed_body["error"]
    assert @agent.placement.reload.staged?
    refute @agent.reload.active?
  end

  test "stop rejects unknown idle probe and pauses admission without disabling the resident's ongoing access" do
    @agent.update_columns(active: true, paused: false, scheduled_wakes_enabled: true)
    transport = Object.new
    transport.define_singleton_method(:idle!) { raise Agents::Portability::Error, "Unknown execution state" }
    sandbox = Object.new
    sandbox.define_singleton_method(:stop!) { flunk "Unknown execution must not be stopped" }
    Agents::Portability::Transport.stub(:new, transport) do
      Agents::Sandbox.stub(:new, sandbox) do
        post portability_stop_account_agent_path(@account, @agent), params: { confirmed: true }
      end
    end
    assert_response :unprocessable_entity
    assert @agent.reload.active?
    assert @agent.paused?
    assert @agent.scheduled_wakes_enabled?
  end

  test "successful stop disables the resident only after the stopped probe" do
    @agent.update_columns(active: true, paused: false)
    agent = @agent
    transport = Object.new
    transport.define_singleton_method(:idle!) { true }
    transport.define_singleton_method(:stopped!) { agent.reload.active? || raise("disabled before stop was verified") }
    sandbox = Object.new
    sandbox.define_singleton_method(:stop!) { true }

    Agents::Portability::Transport.stub(:new, transport) do
      Agents::Sandbox.stub(:new, sandbox) do
        post portability_stop_account_agent_path(@account, @agent), params: { confirmed: true }
      end
    end

    assert_response :see_other
    refute @agent.reload.active?
    assert @agent.paused?
  end

  test "native source activation preserves schedule preference and import activation does not" do
    [ false, true ].each do |imported|
      @agent.update_columns(runtime: "offline", active: false, paused: true, scheduled_wakes_enabled: true,
        portability_custody: imported ? { "export_id" => SecureRandom.uuid } : {})
      transport = Object.new
      transport.define_singleton_method(:stopped!) { true }
      sandbox = Object.new
      agent = @agent
      sandbox.define_singleton_method(:spawn!) { agent.update_columns(runtime: "external") }
      Agents::Portability::Transport.stub(:new, transport) do
        Agents::Sandbox.stub(:new, sandbox) do
          post portability_activate_account_agent_path(@account, @agent), params: { confirmed: true }
        end
      end
      assert_response :see_other
      assert @agent.reload.active?
      refute @agent.paused?
      assert_equal !imported, @agent.scheduled_wakes_enabled?
    end
  end
  test "private download streams a tempfile and sets attachment headers" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "synthetic.tar.gz")
      File.binwrite(path, "synthetic private archive")
      exporter = ->(_, exporter:, &block) { block.call(path) }
      Agents::Portability::Export.stub(:call, exporter) do
        get portable_export_account_agent_path(@account, @agent)
      end
      assert_response :success
      assert_equal "application/gzip", response.media_type
      assert_equal "private, no-store", response.headers["Cache-Control"]
      assert_match "attachment", response.headers["Content-Disposition"]
      assert_equal "synthetic private archive", response.body
    end
  end

  test "external imported profile stop refusal does not mutate source" do
    @agent.update_columns(home_profile: "portable_v1", portable_home_id: "synthetic", active: true, paused: false)
    post portability_stop_account_agent_path(@account, @agent), params: { confirmed: true }
    assert_response :unprocessable_entity
    assert @agent.reload.active?
    refute @agent.paused?
    get edit_account_agent_path(@account, @agent)
    assert_nil inertia_shared_props.dig("portability", "stop_url")
    assert_nil inertia_shared_props.dig("portability", "activate_url")
  end

end

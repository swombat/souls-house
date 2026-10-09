require "test_helper"
require_relative "../../support/github_import_fixtures"

class Agents::VmBirthPolicyTest < ActiveSupport::TestCase

  include GithubImportFixtures

  CONFIGURED = CloudProcurement::Config.new(
    image_id: 1, ssh_key_ids: [ 2 ], locations: [ "fsn1" ], rails_url: "https://house.test", runner_commands: true
  )

  setup do
    @setting = Setting.instance
    @account = accounts(:personal_account)
    @user = users(:user_1)
  end

  # backups: whether slice 4's VM backups exist on this house.
  def policy(config: CONFIGURED, token: "token", backups: true)
    Agents::VmBirthPolicy.new(setting: @setting.reload, procurement_config: config, api_token: token).tap do |policy|
      policy.define_singleton_method(:vm_backups_available?) { backups }
    end
  end

  def vm_placement!(state: "pending")
    agent = agents(:research_assistant)
    AgentPlacement.create!(agent: agent, backend: "hetzner_cloud", state: state,
      provider_server_id: (state == "ready" ? 4242 : nil))
  end

  test "with the switch off everything is allowed and nothing is counted against anyone" do
    @setting.update!(new_residents_on_vm: false, vm_resident_limit: 0)
    assert_nil policy(config: CloudProcurement::Config.new(image_id: nil, ssh_key_ids: [], locations: [], rails_url: nil)).refusal
    assert_nil policy.refusal(kind: :import)
  end

  test "with the switch on, imports are refused before anything else is looked at" do
    @setting.update!(new_residents_on_vm: true, vm_resident_limit: 5)
    assert_equal Agents::VmBirthPolicy::IMPORT_REFUSAL, policy(token: nil).refusal(kind: :import)
  end

  test "with the switch on, an unconfigured house refuses births with the configuration reason" do
    @setting.update!(new_residents_on_vm: true, vm_resident_limit: 5)
    assert_equal Agents::VmBirthPolicy::NOT_CONFIGURED_REFUSAL, policy(token: nil).refusal
    no_commands = CloudProcurement::Config.new(image_id: 1, ssh_key_ids: [ 2 ], locations: [ "fsn1" ],
      rails_url: "https://house.test", runner_commands: false)
    assert_equal Agents::VmBirthPolicy::NOT_CONFIGURED_REFUSAL, policy(config: no_commands).refusal
  end

  test "the cap counts every server that might exist and refuses at the limit" do
    @setting.update!(new_residents_on_vm: true, vm_resident_limit: 1)
    assert_equal 0, policy.vm_count
    assert_nil policy.refusal

    placement = vm_placement!
    assert_equal 1, policy.vm_count
    assert_equal Agents::VmBirthPolicy::LIMIT_REFUSAL, policy.refusal

    # Retired releases the slot; local placements never count.
    placement.update!(state: "retired")
    assert_equal 0, policy.vm_count
    placement.update!(backend: "local", state: "ready")
    assert_equal 0, policy.vm_count
  end

  test "a retired placement with an unsettled purchase still counts" do
    @setting.update!(new_residents_on_vm: true, vm_resident_limit: 1)
    placement = vm_placement!
    CloudProcurementOperation.create!(agent_placement: placement, requested_by: @user, public_id: "cpo-0123456789abcdef",
      approval_reference: "test", server_type: "cx23", location: "fsn1", image_id: 1, ssh_key_ids: [ 2 ],
      provider_name: "souls-house-cpo-0123456789abcdef", state: "create_in_flight", create_sent_at: Time.current)
    placement.update_columns(state: "retired")
    assert_equal 1, policy.vm_count
  end

  test "without VM backups, a configured house with room still refuses rather than creating locally" do
    @setting.update!(new_residents_on_vm: true, vm_resident_limit: 3)
    assert_equal Agents::VmBirthPolicy::NOT_AVAILABLE_REFUSAL, policy(backups: false).refusal
  end

  test "with backups, configuration and room, a house-model birth is allowed and any other model is refused first" do
    @setting.update!(new_residents_on_vm: true, vm_resident_limit: 3)
    assert_nil policy.refusal(model_id: HouseInference::Offering::MODEL_ID)
    assert_equal Agents::VmBirthPolicy::MODEL_REFUSAL, policy(token: nil).refusal(model_id: "openrouter/auto")
  end

  test "admit! commits the placement with its durable admission, and refuses at the cap under the lock" do
    @setting.update!(new_residents_on_vm: true, vm_resident_limit: 1)
    agent = @account.agents.new(name: "Admitted", system_prompt: "Hello", model_id: HouseInference::Offering::MODEL_ID)
    placement = policy.admit!(agent:, requested_by: @user)
    assert agent.persisted?
    assert placement.vm_birth?
    assert_equal [ "hetzner_cloud", "pending", @user ], [ placement.backend, placement.state, placement.birth_requested_by ]

    second = @account.agents.new(name: "Over the cap", system_prompt: "Hello", model_id: HouseInference::Offering::MODEL_ID)
    assert_no_difference [ "Agent.count", "AgentPlacement.count" ] do
      error = assert_raises(Agents::VmBirthPolicy::Refused) { policy.admit!(agent: second, requested_by: @user) }
      assert_equal Agents::VmBirthPolicy::LIMIT_REFUSAL, error.message
    end

    @setting.update!(vm_resident_limit: 5, new_residents_on_vm: false)
    assert_raises(Agents::VmBirthPolicy::Refused) { policy.admit!(agent: second, requested_by: @user) }
  end

  test "hosted birth is refused before anything is committed" do
    @setting.update!(new_residents_on_vm: true, vm_resident_limit: 3)
    birth = Agents::HostedBirth.new(account: @account, creator: @user,
      attributes: { name: "Refused", system_prompt: "Hello", model_id: "openrouter/auto" })
    assert_no_difference [ "Agent.count", "ApiKey.count", "AgentPlacement.count" ] do
      assert_no_enqueued_jobs do
        error = assert_raises(Agents::VmBirthPolicy::Refused) { birth.create! }
        assert_kind_of Agents::HostedProvisioning::ConfigurationError, error
      end
    end
  end

  test "hosted birth is unchanged with the switch off" do
    @setting.update!(new_residents_on_vm: false)
    birth = Agents::HostedBirth.new(account: @account, creator: @user,
      attributes: { name: "Local birth", system_prompt: "Hello", model_id: "openrouter/auto" })
    assert_difference "Agent.count", 1 do
      assert_enqueued_with(job: ProvisionAgentJob) { birth.create! }
    end
  end

  test "an archive import is refused before the archive is even read" do
    @setting.update!(new_residents_on_vm: true)
    archive = Object.new
    archive.define_singleton_method(:validate!) { flunk "a refused import must not read the archive" }
    assert_no_difference [ "Agent.count", "ApiKey.count" ] do
      error = assert_raises(Agents::Portability::Error) do
        Agents::Portability::Import.call(archive, account: @account, user: @user, name: "Copy")
      end
      assert_equal Agents::VmBirthPolicy::IMPORT_REFUSAL, error.message
    end
  end

  test "a GitHub import approved before the switch went on fails with the reason and makes no home" do
    request = import_request
    approve_fixture(request)
    @setting.update!(new_residents_on_vm: true)
    Agents::GithubImportSource.stub(:new, ->(*) { flunk "a refused import must not check out the repository" }) do
      assert_no_difference "Agent.count" do
        GithubResidentImportJob.perform_now(request.id)
      end
    end
    request.reload
    assert_equal "failed", request.status
    assert_equal Agents::VmBirthPolicy::IMPORT_REFUSAL, request.last_error
  end

end

require "test_helper"

class Agents::PortabilityRosterTest < ActionDispatch::IntegrationTest

  include ActionCable::TestHelper
  self.use_transactional_tests = false

  setup do
    @allow_agents = Setting.instance.allow_agents?
    Setting.instance.update!(allow_agents: true)
    @account = Account.create!(name: "Portability roster #{SecureRandom.hex(4)}", account_type: :team)
    @account.add_user!(users(:user_1), role: "owner", skip_confirmation: true)
    @agent = @account.agents.create!(name: "Inactive resident", uuid: SecureRandom.uuid,
      active: false, paused: true, runtime: "offline")
    post login_path, params: { email_address: users(:user_1).email_address, password: "password123" }
  end

  teardown do
    @account.reload.destroy!
    Setting.instance.update!(allow_agents: @allow_agents)
  end

  test "successful callback bypass activation schedules only effective active hint" do
    transport = Object.new
    transport.define_singleton_method(:stopped!) { true }
    sandbox = Object.new
    # Active is already written here, but the controller lock has not committed.
    during_spawn = -> { assert_no_broadcasts(stream) { nil } }
    sandbox.define_singleton_method(:spawn!) { during_spawn.call }
    hints = capture_broadcasts(stream) do
      Agents::Portability::Transport.stub(:new, transport) do
        Agents::Sandbox.stub(:new, sandbox) { activate }
      end
    end
    assert_response :see_other
    assert @agent.reload.active?
    assert_equal [ { "action" => "refresh" } ], hints
  end

  [ true, false ].each do |exit_verified|
    test "failed activation exit verified #{exit_verified} does not hint unchanged active" do
      transport = Object.new
      transport.define_singleton_method(:stopped!) { true }
      sandbox = Object.new
      sandbox.define_singleton_method(:spawn!) { raise "synthetic spawn failure" }
      sandbox.define_singleton_method(:stop!) { raise "synthetic exit unknown" unless exit_verified }
      assert_no_broadcasts(stream) do
        Agents::Portability::Transport.stub(:new, transport) do
          Agents::Sandbox.stub(:new, sandbox) { activate }
        end
      end
      assert_response :unprocessable_entity
      refute @agent.reload.active?
      assert @agent.paused?
    end
  end

  test "rejected confirmation never reaches producer" do
    assert_no_broadcasts(stream) do
      post portability_activate_account_agent_path(@account, @agent), params: { confirmed: false }
    end
    assert_response :unprocessable_entity
  end

  private

  def stream
    "HomeResidentRoster:#{@account.to_param}"
  end

  def activate
    post portability_activate_account_agent_path(@account, @agent), params: { confirmed: true }
  end

end

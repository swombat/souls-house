require "test_helper"

# Real commits through the existing entry points, not transactional-fixture
# after_commit emulation. Everything created here belongs to synthetic accounts.
class GuestDirectoryMutationsTest < ActionDispatch::IntegrationTest

  include ActionCable::TestHelper

  self.use_transactional_tests = false

  setup do
    @user = users(:user_1)
    @home, @receiving = 2.times.map do |i|
      account = Account.create!(name: "Directory request #{i} #{SecureRandom.hex(4)}", account_type: :team)
      account.add_user!(@user, role: "owner", skip_confirmation: true)
      account
    end
    @agent = @home.agents.create!(name: "Synthetic guest", runtime: "external", model_id: "openrouter/auto")
    @old_allow_agents = Setting.instance.allow_agents
    Setting.instance.update!(allow_agents: true)
    clear_enqueued_jobs
  end

  teardown do
    [ @home, @receiving ].compact.each do |account|
      # API keys refer to residents; audit logs deliberately outlive mutations.
      # Remove only this test's synthetic records before their owning accounts.
      account.api_keys.each(&:destroy!)
      AuditLog.where(account_id: account.id).find_each(&:destroy!)
      account.reload.destroy!
    end
    Setting.instance.update!(allow_agents: @old_allow_agents) unless @old_allow_agents.nil?
  end

  test "web join and receiving-side removal refresh both sides" do
    sign_in @user
    assert_directory_refresh do
      post account_guest_memberships_path(@receiving), params: { agent_id: @agent.to_param }
      assert_redirected_to account_agents_path(@receiving)
    end
    membership = @receiving.guest_memberships.last!
    assert_directory_refresh do
      delete account_guest_membership_path(@receiving, membership)
      assert_redirected_to account_agents_path(@receiving)
    end
    assert_not GuestMembership.exists?(membership.id)
  end

  test "home-side web withdrawal refreshes both sides" do
    membership = join
    sign_in @user
    assert_directory_refresh do
      delete account_guest_membership_path(@home, membership)
      assert_redirected_to account_agents_path(@home)
    end
    assert_not GuestMembership.exists?(membership.id)
  end

  test "human API join and withdrawal refresh both sides" do
    receiving_headers = headers_for(account: @receiving)
    home_headers = headers_for(account: @home)
    assert_directory_refresh do
      post api_v1_account_guest_memberships_path, params: { agent_id: @agent.to_param }, headers: receiving_headers, as: :json
      assert_response :created
    end
    membership = @receiving.guest_memberships.last!
    assert_directory_refresh do
      delete api_v1_account_guest_membership_path(membership), headers: home_headers
      assert_response :success
    end
    assert_not GuestMembership.exists?(membership.id)
  end

  test "resident key self-leave with no room seat refreshes both directories" do
    membership = join
    headers = headers_for(agent: @agent)
    assert_empty @agent.chat_agents
    assert_directory_refresh do
      delete api_v1_guest_membership_path(membership), headers: headers
      assert_response :success
    end
    assert_not GuestMembership.exists?(membership.id)
  end

  test "a different resident cannot remove the membership or emit directory hints" do
    membership = join
    other = @receiving.agents.create!(name: "Other synthetic", runtime: "external", model_id: "openrouter/auto")
    headers = headers_for(agent: other)
    assert_no_broadcasts(stream(@home)) do
      assert_no_broadcasts(stream(@receiving)) do
        delete api_v1_guest_membership_path(membership), headers: headers
        assert_response :not_found
      end
    end
    assert GuestMembership.exists?(membership.id)
  end

  private

  def join
    @receiving.guest_memberships.create!(agent: @agent, added_by: @user)
  end

  def headers_for(**options)
    key = ApiKey.generate_for(@user, name: "Synthetic directory request", **options)
    { "Authorization" => "Bearer #{key.raw_token}" }
  end

  def stream(account)
    "GuestDirectory:#{account.to_param}"
  end

  def assert_directory_refresh(&block)
    home_messages = capture_broadcasts(stream(@home)) do
      assert_equal [ { "action" => "refresh" } ], capture_broadcasts(stream(@receiving), &block)
    end
    assert_equal [ { "action" => "refresh" } ], home_messages
  end

end

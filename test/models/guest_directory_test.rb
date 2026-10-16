require "test_helper"

class GuestDirectoryTest < ActiveSupport::TestCase

  include ActionCable::TestHelper

  self.use_transactional_tests = false

  setup do
    @user = users(:user_1)
    @home, @receiving, @unrelated = 3.times.map do |i|
      account = Account.create!(name: "Guest directory #{i} #{SecureRandom.hex(4)}", account_type: :team)
      account.add_user!(@user, role: "owner", skip_confirmation: true)
      account
    end
    @agent = @home.agents.create!(name: "Synthetic guest", runtime: "external", model_id: "openrouter/auto")
    clear_enqueued_jobs
  end

  teardown do
    @agent.memory_vault&.destroy! if Agent.exists?(@agent.id)
    [ @home, @receiving, @unrelated ].each do |account|
      account.reload.destroy! if Account.exists?(account.id)
    end
  end

  test "joining and leaving without room seats invalidate exactly both sides" do
    membership = nil
    assert_refreshes(@home, @receiving) { membership = join }
    assert_empty @agent.chat_agents
    assert_refreshes(@home, @receiving) { membership.destroy! }
  end

  test "helper deduplicates recipients and skips deleted or missing accounts" do
    assert_refreshes(@home, @receiving) do
      GuestDirectory.refresh!([ @home.id, nil, @home.id, @receiving.id, -1 ])
    end
    assert_no_directory { GuestDirectory.refresh!([]) }
    doomed = @unrelated.id
    @unrelated.destroy!
    assert_no_directory { GuestDirectory.refresh!([ doomed ]) }
  end

  test "writes wait for the outer commit and survive later touch save and reload" do
    assert_refreshes(@home, @receiving) do
      GuestMembership.transaction do
        assert_no_directory do
          membership = join
          membership.touch
          membership.save!
          membership.reload
          GuestMembership.transaction(requires_new: true) { membership.touch }
        end
      end
    end
  end

  test "outer rollback and rolled back savepoint create and removal stay silent" do
    membership = join
    assert_no_directory do
      GuestMembership.transaction do
        membership.destroy!
        @agent.update!(name: "Rolled back")
        @home.update!(name: "Rolled back")
        raise ActiveRecord::Rollback
      end
    end
    assert GuestMembership.exists?(membership.id)
    assert_no_directory do
      GuestMembership.transaction do
        GuestMembership.transaction(requires_new: true) do
          GuestMembership.find(membership.id).destroy!
          raise ActiveRecord::Rollback
        end
      end
    end
    GuestMembership.find(membership.id).destroy!
    assert_no_directory do
      GuestMembership.transaction do
        join
        raise ActiveRecord::Rollback
      end
    end
    assert_refreshes(@home, @receiving) { join }
  end

  test "rolled back savepoint does not lose a subsequent committed update" do
    join
    assert_refreshes(@home, @receiving) do
      Agent.transaction do
        Agent.transaction(requires_new: true) do
          @agent.update!(name: "Savepoint")
          raise ActiveRecord::Rollback
        end
        @agent.reload.update!(name: "Committed")
        @agent.touch
      end
    end
  end

  test "guest presentation and eligibility allowlist stays within existing sides" do
    join
    { name: "Renamed", colour: "red", icon: "Moon", active: false, runtime: "offline" }.each do |key, value|
      assert_refreshes(@home, @receiving) { @agent.update!(key => value) }
    end
    assert_refreshes(@home, @receiving) { @agent.update!(active: true) }
    assert GuestMembership.exists?(agent: @agent, account: @receiving), "inactivation does not revoke a guest"
  end

  test "home reassignment captures both homes and the existing receiving side" do
    join
    assert_refreshes(@home, @receiving, @unrelated) { @agent.update!(account: @unrelated) }
  end

  test "join reassignment captures previous and new sides" do
    membership = join
    assert_refreshes(@home, @receiving, @unrelated) { membership.update!(account: @unrelated) }
  end

  test "account presentation and enablement reach the existing counterpart" do
    join
    assert_refreshes(@home, @receiving) { @home.update!(name: "New home") }
    assert_refreshes(@home, @receiving) { @receiving.update!(name: "New receiving") }
    assert_refreshes(@home, @receiving) { @home.disable! }
    assert_refreshes(@home, @receiving) { @home.enable! }
    assert_refreshes(@unrelated) { @unrelated.update!(name: "No guest relationship") }
  end

  test "membership ownership controls refresh locally without removing accepted guests" do
    join
    membership = @receiving.add_user!(users(:existing_user), role: "member", skip_confirmation: true)
    assert_refreshes(@receiving) { membership.update!(role: "owner") }
    assert_refreshes(@receiving) { membership.update!(confirmed_at: nil) }
    assert_refreshes(@receiving) { membership.update!(role: "member") }
    assert_refreshes(@receiving) { membership.destroy! }
    assert GuestMembership.exists?(agent: @agent, account: @receiving)
  end

  test "personal owner profile email and ownership labels reach the other side" do
    join
    @home.update!(account_type: :personal, name: "#{@user.email_address}'s Account")
    profile = @user.profile
    old_first_name = profile.first_name
    old_email = @user.email_address
    owner = @home.owner_membership
    begin
      assert_refreshes_including(@home, @receiving) { profile.update!(first_name: "Directory label") }
      assert_equal "Directory label #{profile.last_name}'s Account", @home.reload.name
      assert_refreshes_including(@home, @receiving) { @user.update!(email_address: "directory-#{SecureRandom.hex(4)}@example.test") }
      assert_refreshes(@home, @receiving) { owner.update!(user: users(:existing_user)) }
    ensure
      profile.update!(first_name: old_first_name)
      @user.update!(email_address: old_email)
    end
  end

  test "agent deletion snapshots the joins before dependent delete_all" do
    membership = join
    observed = nil
    @agent.define_singleton_method(:snapshot_guest_directory) do
      observed = guest_memberships.ids
      super()
    end
    assert_refreshes(@home, @receiving) { @agent.destroy! }
    assert_equal [ membership.id ], observed
    assert_not GuestMembership.exists?(membership.id)
  end

  test "receiving account deletion snapshots joins and refreshes the surviving home" do
    membership = join
    observed = nil
    @receiving.define_singleton_method(:snapshot_guest_directory) do
      observed = guest_memberships.ids
      super()
    end
    assert_refreshes(@home) { @receiving.destroy! }
    assert_equal [ membership.id ], observed
    assert_not GuestMembership.exists?(membership.id)
  end

  test "home account deletion snapshots before agents delete their joins" do
    membership = join
    sibling = @home.agents.create!(name: "Second synthetic guest", runtime: "offline", model_id: "openrouter/auto")
    second_membership = @receiving.guest_memberships.create!(agent: sibling, added_by: @user)
    observed = nil
    @home.define_singleton_method(:snapshot_guest_directory) do
      observed = GuestMembership.where(agent_id: agents.select(:id)).ids
      super()
    end
    assert_refreshes(@receiving) { @home.destroy! }
    assert_equal [ membership.id, second_membership.id ].sort, observed.sort
    assert_not GuestMembership.exists?(membership.id)
    assert_not GuestMembership.exists?(second_membership.id)
  end

  test "denied agent and account destruction and outer deletion rollback stay silent" do
    membership = join
    @agent.create_memory_vault!
    assert_no_directory do
      assert_not @agent.destroy
      assert_not @home.destroy
    end
    assert GuestMembership.exists?(membership.id)
    @agent.memory_vault.destroy!
    @agent.reload
    assert_no_directory do
      Account.transaction do
        @receiving.destroy!
        raise ActiveRecord::Rollback
      end
    end
    assert GuestMembership.exists?(membership.id)
    assert Account.exists?(@receiving.id)
  end

  test "invalid guest writes and failed updates stay silent" do
    assert_no_directory do
      assert_not @home.guest_memberships.create(agent: @agent, added_by: @user).persisted?
      assert_not @agent.update(name: "")
    end
  end

  test "ordinary messages health heartbeat and unrelated feature traffic stay quiet" do
    join
    chat = @home.chats.create!(title: "Synthetic quiet chat", model_id: "openrouter/auto", manual_responses: true, agents: [ @agent ])
    assert_no_directory do
      chat.messages.create!(role: "user", content: "Ordinary message")
      chat.update!(title: "A room rename")
      @agent.update!(health_state: "unhealthy", last_health_check_at: Time.current, consecutive_health_failures: 1)
      @agent.update!(heartbeat_wakes_per_day: 4)
      @agent.touch
      @home.update!(logo_colour: "moss")
      @home.whiteboards.create!(name: "Unrelated", content: "No directory change")
      IntegrationStatus.refresh!([ @home.id ])
      RhythmActivity.broadcast_for(@home)
    end
  end

  test "a resident without a guest relationship does not discover other homes" do
    assert_refreshes(@home) { @agent.update!(name: "No remote discovery") }
    assert_refreshes(@home) { @home.agents.create!(name: "New local", runtime: "offline", model_id: "openrouter/auto") }
  end

  private

  def join
    @receiving.guest_memberships.create!(agent: @agent, added_by: @user)
  end

  def directory_events
    events = []
    subscriber = ->(*args) do
      payload = args.last
      events << [ payload[:broadcasting], payload[:message] ] if payload[:broadcasting].start_with?("GuestDirectory:")
    end
    ActiveSupport::Notifications.subscribed(subscriber, "broadcast.action_cable") do
      yield
    end
    events.each { |_, payload| assert_equal({ action: "refresh" }, payload) }
    events.map(&:first)
  end

  def assert_refreshes(*accounts, &block)
    assert_equal accounts.map { |account| "GuestDirectory:#{account.to_param}" }.sort, directory_events(&block).sort
  end

  def assert_refreshes_including(*accounts, &block)
    events = directory_events(&block)
    accounts.each { |account| assert_includes events, "GuestDirectory:#{account.to_param}" }
    assert_not_includes events, "GuestDirectory:#{@unrelated.to_param}"
  end

  def assert_no_directory(&block)
    assert_empty directory_events(&block)
  end

end

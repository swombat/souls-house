require "test_helper"

class GuestDiscoveryTest < ActiveSupport::TestCase

  self.use_transactional_tests = false

  setup do
    @first, @second, @pending = users(:user_1), users(:existing_user), users(:unconfirmed_user)
    @home, @other = 2.times.map do |i|
      Account.create!(name: "Discovery #{i} #{SecureRandom.hex(4)}", account_type: :team)
    end
    @home.add_user!(@first, role: "owner", skip_confirmation: true)
    @home.add_user!(@second, role: "member", skip_confirmation: true)
    @invitation = @home.memberships.create!(user: @pending, role: "member", invited_by: @first)
    @other.add_user!(@second, role: "owner", skip_confirmation: true)
    @agent = @home.agents.create!(name: "Synthetic discovery", runtime: "external", model_id: "openrouter/auto")
    clear_enqueued_jobs
  end

  teardown do
    @agent.memory_vault&.destroy! if @agent && Agent.exists?(@agent.id)
    [ @home, @other ].each { |account| account.reload.destroy! if Account.exists?(account.id) }
  end

  test "deduplicate recipients and skip missing users" do
    assert_refreshes(@first, @second) { GuestDiscovery.refresh!([ @first.id, nil, @first.id, @second.id, -1 ]) }
    assert_quiet { GuestDiscovery.refresh!([]) }
    assert_quiet { GuestDiscovery.refresh!([ -1 ]) }
  end

  test "resident creation and allowlisted eligibility and presentation changes reach every confirmed home member" do
    assert_refreshes(@first, @second) do
      @home.agents.create!(name: "New discovery", runtime: "external", model_id: "openrouter/auto")
    end
    { active: false, runtime: "offline", name: "Renamed discovery", colour: "red", icon: "Moon" }.each do |key, value|
      assert_refreshes(@first, @second) { @agent.update!(key => value) }
    end
    assert_refreshes(@first, @second) { @agent.update!(active: true, runtime: "external") }
  end

  test "moving a resident captures old and new home members once" do
    assert_refreshes(@first, @second) { @agent.update!(account: @other) }
    assert_refreshes(@second) { @agent.destroy! }
  end

  test "account disable and enable invalidate confirmed members but presentation does not" do
    assert_refreshes(@first, @second) { @home.disable! }
    assert_refreshes(@first, @second) { @home.enable! }
    assert_quiet { @home.update!(name: "Not a candidate dependency", logo_colour: "moss") }
  end

  test "confirmation and revocation include the changed human and do not revoke accepted guests" do
    guest = @other.guest_memberships.create!(agent: @agent, added_by: @second)
    assert_refreshes(@pending) { @invitation.confirm! }
    assert_refreshes(@pending) { @invitation.update!(confirmed_at: nil) }
    assert GuestMembership.exists?(guest.id)
    assert_quiet { @invitation.destroy! }
    membership = @home.memberships.find_by!(user: @second)
    assert_refreshes(@second) { membership.destroy! }
    assert GuestMembership.exists?(guest.id)
  end

  test "membership reassignment targets only old and new confirmed identities" do
    @invitation.destroy!
    assert_refreshes(@second, @pending) do
      @home.memberships.find_by!(user: @second).update!(user: @pending, confirmed_at: Time.current)
    end
    assert_refreshes(@pending) { @home.memberships.find_by!(user: @pending).destroy! }
  end

  test "pending to confirmed reassignment does not notify the old pending identity" do
    assert_refreshes(users(:regular_user)) do
      @invitation.update!(user: users(:regular_user), confirmed_at: Time.current)
    end
  end

  test "confirmed to pending reassignment does not notify the new pending identity" do
    membership = @home.memberships.find_by!(user: @second)
    assert_refreshes(@second) { membership.update!(user: users(:regular_user), confirmed_at: nil) }
  end

  test "moving confirmed membership between accounts invalidates its human" do
    @other.add_user!(@first, role: "owner", skip_confirmation: true)
    @other.memberships.find_by!(user: @second).destroy!
    membership = @home.memberships.find_by!(user: @second)
    assert_refreshes(@second) { membership.update!(account: @other) }
  end

  test "pending invitation and token bookkeeping and confirmed roles stay quiet" do
    assert_quiet do
      @invitation.resend_invitation!
      @invitation.update!(confirmation_sent_at: 2.days.ago, invited_at: 3.days.ago)
      @home.memberships.find_by!(user: @second).update!(role: "admin")
      @invitation.touch
    end
  end

  test "markers wait for outer commit and capture the write despite later touch and reload" do
    assert_refreshes(@first, @second) do
      Agent.transaction do
        assert_quiet do
          @agent.update!(name: "Committed discovery")
          @agent.touch
          @agent.reload
          Agent.transaction(requires_new: true) { @agent.touch }
        end
      end
    end
  end

  test "outer and savepoint rollback and failed writes remain silent" do
    assert_quiet do
      Account.transaction do
        @home.disable!
        @invitation.confirm!
        @agent.update!(name: "Never visible")
        raise ActiveRecord::Rollback
      end
      Agent.transaction do
        Agent.transaction(requires_new: true) do
          @agent.reload.destroy!
          raise ActiveRecord::Rollback
        end
      end
      assert_not @agent.reload.update(name: "")
    end
  end

  test "rolled back savepoint does not swallow a later committed change" do
    assert_refreshes(@first, @second) do
      Agent.transaction do
        Agent.transaction(requires_new: true) do
          @agent.update!(name: "Savepoint")
          raise ActiveRecord::Rollback
        end
        @agent.reload.update!(name: "Committed")
      end
    end
  end

  test "account deletion snapshots confirmed members before dependent callbacks remove them" do
    guest = @other.guest_memberships.create!(agent: @agent, added_by: @second)
    observed_members = observed_guests = nil
    @home.define_singleton_method(:snapshot_guest_discovery) do
      observed_members = memberships.ids
      observed_guests = GuestMembership.where(agent_id: agents.select(:id)).ids
      super()
    end
    member_ids = @home.memberships.ids
    assert_refreshes(@first, @second) { @home.destroy! }
    assert_equal member_ids.sort, observed_members.sort
    assert_equal [ guest.id ], observed_guests
    assert_not GuestMembership.exists?(guest.id)
  end

  test "denied destruction and rolled back account deletion emit nothing" do
    @agent.create_memory_vault!
    assert_quiet do
      assert_not @agent.destroy
      assert_not @home.destroy
    end
    @agent.memory_vault.destroy!
    @home.reload
    assert_quiet do
      Account.transaction do
        @home.destroy!
        raise ActiveRecord::Rollback
      end
    end
    assert Account.exists?(@home.id)
  end

  test "guest joins ordinary messages health heartbeat and unrelated settings stay quiet" do
    chat = @home.chats.create!(title: "Quiet discovery", model_id: "openrouter/auto", manual_responses: true, agents: [ @agent ])
    assert_quiet do
      guest = @other.guest_memberships.create!(agent: @agent, added_by: @second)
      guest.destroy!
      chat.messages.create!(role: "user", content: "Ordinary message")
      @agent.update!(health_state: "unhealthy", last_health_check_at: Time.current, consecutive_health_failures: 1)
      @agent.update!(heartbeat_wakes_per_day: 4)
      @agent.touch
      @home.whiteboards.create!(name: "Unrelated", content: "No discovery")
      IntegrationStatus.refresh!([ @home.id ])
      RhythmActivity.broadcast_for(@home)
    end
  end

  private

  def discovery_events
    events = []
    subscriber = ->(*args) do
      payload = args.last
      events << [ payload[:broadcasting], payload[:message] ] if payload[:broadcasting].start_with?("GuestDiscovery:")
    end
    ActiveSupport::Notifications.subscribed(subscriber, "broadcast.action_cable") { yield }
    events.each { |_, payload| assert_equal({ action: "refresh" }, payload) }
    events.map(&:first)
  end

  def assert_refreshes(*users, &block)
    assert_equal users.map { |user| "GuestDiscovery:#{user.to_param}" }.sort, discovery_events(&block).sort
  end

  def assert_quiet(&block)
    assert_empty discovery_events(&block)
  end

end

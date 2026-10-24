require "test_helper"

class HomeResidentRosterTest < ActiveSupport::TestCase

  include ActionCable::TestHelper
  self.use_transactional_tests = false

  setup do
    @home = Account.create!(name: "Roster #{SecureRandom.hex(4)}", account_type: :team)
    @other = Account.create!(name: "Other roster #{SecureRandom.hex(4)}", account_type: :team)
    @agent = @home.agents.create!(name: "Roster resident", runtime: "offline")
    [ @home, @other ].each { |account| account.add_user!(users(:user_1), role: "owner", skip_confirmation: true) }
    clear_enqueued_jobs
  end

  teardown do
    [ @home, @other ].each { |account| account.reload.destroy! }
  end

  test "create rename active transfer and destroy affect only old and new homes" do
    resident = nil
    marker(@home) { resident = @home.agents.create!(name: "Arrival", runtime: "offline") }
    marker(@home) { resident.update!(name: "Renamed") }
    marker(@home) { resident.update!(active: false) }
    marker(@home) { marker(@other) { resident.update!(account: @other) } }
    assert_no_broadcasts(stream(@home)) { marker(@other) { resident.destroy! } }
  end

  test "snapshot survives later saves transfers and destruction in one transaction" do
    marker(@home) do
      marker(@other, count: 2) do
        Agent.transaction do
          @agent.update!(account: @other)
          @agent.touch
          @agent.destroy!
        end
      end
    end
  end

  test "health runtime presentation bookkeeping and guest placement stay quiet" do
    assert_no_broadcasts(stream(@home)) do
      assert_no_broadcasts(stream(@other)) do
        @agent.update!(health_state: "healthy", last_health_check_at: Time.current)
        @agent.update!(runtime: "external", colour: Agent::VALID_COLOURS.first)
        @agent.touch
        GuestMembership.create!(agent: @agent, account: @other, added_by: users(:user_1))
      end
    end
  end

  test "guest homes receive no roster hints for resident changes or guest removal" do
    guest = GuestMembership.create!(agent: @agent, account: @other, added_by: users(:user_1))
    assert_no_broadcasts(stream(@other)) do
      marker(@home) { @agent.update!(name: "Visiting resident renamed", active: false) }
      assert_no_broadcasts(stream(@home)) { guest.destroy! }
      marker(@home) { @agent.destroy! }
    end
  end

  test "non roster configuration and callback bypass bookkeeping stay quiet" do
    assert_no_broadcasts(stream(@home)) do
      @agent.update!(paused: true, icon: Agent::VALID_ICONS.last)
      @agent.update_columns(journal_stats_requested_at: Time.current)
      Agent.where(id: @agent.id).update_all(follow_through: true, updated_at: Time.current)
    end
  end

  test "rollback and rolled back savepoint are quiet and later touch retains earlier hint" do
    assert_no_broadcasts(stream(@home)) do
      Agent.transaction do
        @agent.update!(name: "Outer rollback")
        raise ActiveRecord::Rollback
      end
      @agent.reload
      Agent.transaction do
        Agent.transaction(requires_new: true) do
          @agent.update!(active: false)
          raise ActiveRecord::Rollback
        end
      end
    end
    @agent.reload
    marker(@home) do
      Agent.transaction do
        assert_no_broadcasts(stream(@home)) { @agent.update!(name: "Committed"); @agent.touch }
      end
    end
  end

  private

  def stream(account)
    "HomeResidentRoster:#{account.to_param}"
  end

  def marker(account, count: 1)
    assert_equal Array.new(count) { { "action" => "refresh" } }, capture_broadcasts(stream(account)) { yield }
  end

end

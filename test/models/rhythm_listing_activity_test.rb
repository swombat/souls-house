require "test_helper"
require "action_cable/test_helper"

class RhythmListingActivityTest < ActiveSupport::TestCase

  include ActionCable::TestHelper
  self.use_transactional_tests = false

  setup do
    @user = users(:user_1)
    @account = Account.create!(name: "Synthetic listing #{SecureRandom.hex(4)}", account_type: "team")
    @account.memberships.create!(user: @user, role: "owner", confirmed_at: Time.current)
    @agent = @account.agents.create!(name: "Synthetic resident", runtime: "external", model_id: "anthropic/claude-opus-5.5")
    @other = @account.agents.create!(name: "Synthetic second", runtime: "external", model_id: "anthropic/claude-opus-5.5")
    @rhythm = Rhythm.create!(account: @account, creator: @user, agents: [ @agent ], title: "Synthetic rhythm",
      opening: "Synthetic opening", cadence: "daily", time_of_day: "09:00", timezone: "UTC")
    MessageDispatchJob.stub(:perform_later, ->(*) { }) do
      @chat = @rhythm.fire!(manual: true, request_key: SecureRandom.uuid).occurrence.chat
    end
    assert @chat.quiet_rhythm_run?
  end

  teardown do
    @rhythm.destroy! if Rhythm.exists?(@rhythm.id)
    @account.destroy!
  end

  test "ordinary assistant messages and chat touches do not refresh rhythm readers" do
    assert_no_broadcasts(stream) do
      @chat.messages.create!(role: "assistant", agent: @agent, content: "Synthetic answer", suppress_automatic_dispatch: true)
      @chat.touch
    end
  end

  test "only a listing transition from a human reply or its removal emits" do
    reply = nil
    assert_refresh { reply = human_reply }
    assert_no_broadcasts(stream) { reply.update!(content: "Edited reply") }
    second = nil
    assert_no_broadcasts(stream) { second = human_reply }
    assert_no_broadcasts(stream) { reply.discard! }
    assert_refresh { second.discard! }
    assert_refresh { second.undiscard! }
    assert_refresh { second.destroy! }
  end

  test "seats and flags refresh only when they change quiet status" do
    seat = nil
    assert_refresh { seat = @chat.chat_agents.create!(agent: @other) }
    assert_refresh { seat.destroy! }
    flag = nil
    assert_refresh do
      flag = ReplyExpectation.record!(message: @chat.messages.first, user: @user, score: 0.9, classifier_version: "synthetic")
    end
    assert_no_broadcasts(stream) { flag.update!(state: :dismissed) }
    assert_refresh { flag.destroy! }
  end

  test "chat title discard restore and deletion refresh recent run metadata" do
    assert_refresh { @chat.update!(title: "Changed title") }
    assert_refresh { @chat.discard! }
    assert_refresh { @chat.undiscard! }
    assert_refresh { @chat.destroy! }
  end

  test "rolled back metadata and listing changes emit nothing" do
    assert_no_broadcasts(stream) do
      Chat.transaction do
        @chat.update!(title: "Rolled back")
        human_reply
        @chat.chat_agents.create!(agent: @other)
        raise ActiveRecord::Rollback
      end
    end
    assert @chat.reload.quiet_rhythm_run?
  end

  test "later touches or rolled back savepoints cannot erase a committed transition" do
    assert_refresh do
      Message.transaction do
        reply = human_reply
        Message.transaction(requires_new: true) do
          reply.update!(content: "Rolled back edit")
          raise ActiveRecord::Rollback
        end
        @chat.touch
      end
    end
    assert_refresh do
      Chat.transaction do
        @chat.update!(title: "Committed title")
        @chat.touch
      end
    end
  end

  test "another accounts stream never receives these markers" do
    assert_no_broadcasts("RhythmActivity:#{accounts(:existing_user_account).obfuscated_id}") do
      human_reply
      @chat.update!(title: "Changed title")
    end
  end

  private

  def stream
    "RhythmActivity:#{@account.obfuscated_id}"
  end

  def human_reply
    @chat.messages.create!(role: "user", user: @user, content: "Synthetic reply", suppress_automatic_dispatch: true)
  end

  def assert_refresh
    assert_equal [ { "action" => "refresh" } ], capture_broadcasts(stream) { yield }
  end

end

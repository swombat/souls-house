require "test_helper"

class TelegramPresentationTest < ActiveSupport::TestCase

  include ActionCable::TestHelper
  self.use_transactional_tests = false

  setup do
    @account = Account.create!(name: "Telegram hints #{SecureRandom.hex(4)}", account_type: :team)
    @agent = @account.agents.create!(name: "Synthetic bot", runtime: "offline", model_id: "openrouter/auto")
    @other = @account.agents.create!(name: "Other synthetic bot", runtime: "offline", model_id: "openrouter/auto")
    @user = users(:user_1)
  end

  teardown do
    @account.reload.destroy!
  end

  test "active arrival block unblock reassignment and removal refresh the actual count" do
    subscription = nil
    assert_broadcasts(stream(@agent), 1) { subscription = create_subscription }
    assert_equal 1, @agent.telegram_subscriptions.active.count
    assert_broadcasts(stream(@agent), 1) { subscription.mark_blocked! }
    assert_equal 0, @agent.telegram_subscriptions.active.count
    assert_broadcasts(stream(@agent), 1) { subscription.update!(blocked: false) }
    assert_broadcasts(stream(@agent), 1) do
      assert_broadcasts(stream(@other), 1) { subscription.update!(agent: @other) }
    end
    assert_broadcasts(stream(@other), 1) { subscription.destroy! }
    assert_equal 0, @other.telegram_subscriptions.active.count
  end

  test "blocked arrivals removals same predicate and message bookkeeping stay quiet" do
    subscription = create_subscription
    assert_no_broadcasts(stream(@agent)) do
      subscription.update!(telegram_username: "synthetic", telegram_chat_id: 987654321)
      subscription.request_runtime_reset!
      subscription.touch
      subscription.telegram_messages.create!(role: "user", text: "Synthetic incoming message", sent_at: Time.current)
      subscription.update!(blocked: false)
      blocked = create_subscription(blocked: true, user: users(:regular_user), telegram_chat_id: 123456789)
      blocked.update!(telegram_username: "another")
      blocked.destroy!
    end
  end

  test "inactive reassignment stays quiet and simultaneous membership changes notify only affected residents" do
    subscription = create_subscription(blocked: true)
    assert_no_broadcasts(stream(@agent)) do
      assert_no_broadcasts(stream(@other)) { subscription.update!(agent: @other) }
    end
    assert_no_broadcasts(stream(@other)) do
      assert_broadcasts(stream(@agent), 1) { subscription.update!(agent: @agent, blocked: false) }
    end
    assert_no_broadcasts(stream(@other)) do
      assert_broadcasts(stream(@agent), 1) { subscription.update!(agent: @other, blocked: true) }
    end
  end

  test "null blocked is inactive just like the SQL active predicate" do
    subscription = nil
    assert_no_broadcasts(stream(@agent)) do
      subscription = create_subscription(blocked: nil)
      subscription.update!(blocked: true)
      subscription.update!(blocked: nil)
    end
    assert_equal 0, @agent.telegram_subscriptions.active.count
    assert_broadcasts(stream(@agent), 1) { subscription.update!(blocked: false) }
    assert_equal 1, @agent.telegram_subscriptions.active.count
    assert_broadcasts(stream(@agent), 1) { subscription.update!(blocked: nil) }
    assert_equal 0, @agent.telegram_subscriptions.active.count
  end

  test "a later touch cannot erase a count hint and rolled back block reassignment and destroy stay silent" do
    subscription = create_subscription
    assert_broadcasts(stream(@agent), 1) do
      TelegramSubscription.transaction do
        subscription.mark_blocked!
        subscription.touch
      end
    end
    subscription.update!(blocked: false)
    assert_no_broadcasts(stream(@agent)) do
      assert_no_broadcasts(stream(@other)) do
        TelegramSubscription.transaction do
          subscription.update!(agent: @other, blocked: true)
          subscription.destroy!
          raise ActiveRecord::Rollback
        end
      end
    end
    assert_equal 1, @agent.telegram_subscriptions.active.count
    assert_equal 0, @other.telegram_subscriptions.active.count
  end

  test "outer commit defers hints and outer or savepoint rollback drops them" do
    assert_broadcasts(stream(@agent), 1) do
      TelegramSubscription.transaction do
        assert_no_broadcasts(stream(@agent)) { create_subscription }
      end
    end
    assert_no_broadcasts(stream(@agent)) do
      TelegramSubscription.transaction do
        create_subscription(user: users(:regular_user), telegram_chat_id: 234567891)
        raise ActiveRecord::Rollback
      end
      TelegramSubscription.transaction do
        TelegramSubscription.transaction(requires_new: true) do
          create_subscription(user: users(:regular_user), telegram_chat_id: 345678912)
          raise ActiveRecord::Rollback
        end
      end
    end
  end

  test "configuration username transitions signal but token rotation is not a presentation change" do
    @agent.stub :manage_telegram_webhook, -> { } do
      assert_broadcasts(stream(@agent), 1) do
        @agent.update!(telegram_bot_username: "synthetic_bot", telegram_bot_token: "PRIVATE-SYNTHETIC-TOKEN")
      end
      assert_no_broadcasts(stream(@agent)) { @agent.update!(telegram_bot_token: "PRIVATE-ROTATED-TOKEN") }
      assert_broadcasts(stream(@agent), 1) { @agent.update!(telegram_bot_username: "renamed_bot") }
      assert_broadcasts(stream(@agent), 1) { @agent.update!(telegram_bot_token: nil) }
    end
    assert broadcasts(stream(@agent)).all? { |payload| JSON.parse(payload) == { "action" => "refresh" } }
  end

  private

  def stream(agent)
    "TelegramPresentation:#{agent.to_param}"
  end

  def create_subscription(**attributes)
    TelegramSubscription.create!({ agent: @agent, user: @user, telegram_chat_id: 876543219, blocked: false }.merge(attributes))
  end

end

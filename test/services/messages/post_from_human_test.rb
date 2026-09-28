require "test_helper"

class Messages::PostFromHumanTest < ActiveSupport::TestCase

  include ActiveJob::TestHelper

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = @account.agents.create!(name: "Grok", system_prompt: "Test", runtime: "external")
    @group_chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
    @group_chat.agent_ids = [ @agent.id ]
    @group_chat.save!
  end

  test "creates a human message and wakes the residents it mentions" do
    result = nil
    assert_enqueued_jobs 1, only: MessageDispatchJob do
      result = post("Hey @Grok, what do you think?")
    end

    assert result.created?
    dispatch = result.message.message_dispatch
    assert_equal [ "pending", [ @agent.id ], @user ], [ dispatch.status, dispatch.target_agent_ids, dispatch.user ]
    assert_in_delta dispatch.accepted_at + 10.minutes, dispatch.expires_at, 0.001
    assert_equal "user", result.message.role
    assert_equal @user, result.message.user
    assert result.message.persisted?
  end

  test "wakes no one when no resident is mentioned" do
    assert_no_enqueued_jobs(only: MessageDispatchJob) do
      assert post("Hello everyone").created?
    end
  end

  test "an immediate repeat is a duplicate and wakes no one" do
    post("Hey @Grok")

    assert_no_enqueued_jobs(only: MessageDispatchJob) do
      assert_no_difference "Message.count" do
        assert post("Hey @Grok").duplicate?
      end
    end
  end

  test "blank content is invalid and wakes no one" do
    assert_no_enqueued_jobs(only: MessageDispatchJob) do
      result = post("")
      assert result.invalid?
      assert result.message.errors.any?
    end
  end

  test "an invalid audio signature still posts the text" do
    result = Messages::PostFromHuman.new(
      chat: @group_chat, user: @user, content: "With audio", audio_signed_id: "bogus"
    ).call

    assert result.created?
    assert_not result.message.audio_recording.attached?
  end

  test "on_persisted runs after save and before any resident is woken" do
    seen = nil
    result = Messages::PostFromHuman.new(chat: @group_chat, user: @user, content: "Hey @Grok").call(
      on_persisted: ->(message) { seen = [ message.persisted?, enqueued_jobs.count { |j| j["job_class"] == "MessageDispatchJob" } ] }
    )

    assert result.created?
    assert_equal [ true, 0 ], seen
    assert_enqueued_jobs 1, only: MessageDispatchJob
  end

  test "anything raising before commit leaves no message, audit, dispatch or job" do
    assert_no_difference [ "Message.count", "MessageDispatch.count" ] do
      assert_no_enqueued_jobs(only: MessageDispatchJob) do
        MessageDispatch.stub(:accept!, ->(**) { raise "synthetic failure after the dispatch insert" }) do
          assert_raises(RuntimeError) { post("Hey @Grok") }
        end
      end
    end
  end

  test "a failed enqueue after commit leaves an accepted send with a pending dispatch" do
    result = nil
    MessageDispatchJob.stub(:perform_later, ->(*) { raise "queue down" }) { result = post("Hey @Grok") }

    assert result.created?
    assert_equal "pending", result.message.message_dispatch.status
  end

  test "a send needing a wake is refused before anything is written while live activity is off" do
    previous = ENV["SOULSHOUSE_LIVE_ACTIVITY"]
    ENV["SOULSHOUSE_LIVE_ACTIVITY"] = "0"
    assert_no_difference [ "Message.count", "MessageDispatch.count" ] do
      assert post("Hey @Grok").dispatch_unavailable?
    end
    assert post("No one mentioned").created?
  ensure
    ENV["SOULSHOUSE_LIVE_ACTIVITY"] = previous
  end

  test "on_persisted is not called for a duplicate" do
    post("Hey @Grok")
    called = false
    Messages::PostFromHuman.new(chat: @group_chat, user: @user, content: "Hey @Grok").call(on_persisted: ->(*) { called = true })

    assert_not called
  end

  private

  def post(content)
    Messages::PostFromHuman.new(chat: @group_chat, user: @user, content: content).call
  end

end

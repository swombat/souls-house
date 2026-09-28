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
    assert_enqueued_with(job: AllAgentsResponseJob, args: [ @group_chat, [ @agent.id ] ]) do
      result = post("Hey @Grok, what do you think?")
    end

    assert result.created?
    assert_equal "user", result.message.role
    assert_equal @user, result.message.user
    assert result.message.persisted?
  end

  test "wakes no one when no resident is mentioned" do
    assert_no_enqueued_jobs(only: AllAgentsResponseJob) do
      assert post("Hello everyone").created?
    end
  end

  test "an immediate repeat is a duplicate and wakes no one" do
    post("Hey @Grok")

    assert_no_enqueued_jobs(only: AllAgentsResponseJob) do
      assert_no_difference "Message.count" do
        assert post("Hey @Grok").duplicate?
      end
    end
  end

  test "blank content is invalid and wakes no one" do
    assert_no_enqueued_jobs(only: AllAgentsResponseJob) do
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
      on_persisted: ->(message) { seen = [ message.persisted?, enqueued_jobs.count { |j| j[:job] == AllAgentsResponseJob } ] }
    )

    assert result.created?
    assert_equal [ true, 0 ], seen
    assert_enqueued_jobs 1, only: AllAgentsResponseJob
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

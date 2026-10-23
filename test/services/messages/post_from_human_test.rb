require "test_helper"

class Messages::PostFromHumanTest < ActiveSupport::TestCase

  include ActiveJob::TestHelper

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = @account.agents.create!(name: "Grok", system_prompt: "Test", runtime: "external")
    @group_chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
    # A second resident keeps this a mention room: with one resident, a human
    # message wakes it automatically and a mention is not a separate wake.
    @bystander = @account.agents.create!(name: "Bystander", system_prompt: "Test", runtime: "external")
    @group_chat.agent_ids = [ @agent.id, @bystander.id ]
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

  test "a busy lowest-ID namesake gets the held wake without dispatching its free namesake" do
    duplicate = @account.agents.create!(name: "grok", system_prompt: "Test", runtime: "external")
    @group_chat.agents << duplicate
    AgentRuntimeInteraction.reserve!(agent: @agent, chat: @group_chat)

    assert_no_difference "MessageDispatch.count" do
      assert_difference "PendingWake.count", 1 do
        assert post("Hey @Grok").created?
      end
    end
    wake = PendingWake.open.find_by!(chat: @group_chat)
    assert_equal @agent, wake.agent
    assert_equal [ "message", @user.id ], wake.sources.sole.values_at("kind", "user_id")
    assert_equal @group_chat.messages.last, wake.sources.sole.message
  end

  test "a free lowest-ID namesake is dispatched without queueing its busy namesake" do
    duplicate = @account.agents.create!(name: "grok", system_prompt: "Test", runtime: "external")
    @group_chat.agents << duplicate
    AgentRuntimeInteraction.reserve!(agent: duplicate, chat: @group_chat)

    result = nil
    assert_no_difference "PendingWake.count" do
      assert_enqueued_jobs 1, only: MessageDispatchJob do
        result = post("Hey @Grok")
      end
    end
    assert result.created?
    assert_equal [ @agent.id ], result.message.message_dispatch.target_agent_ids
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

  test "an after-commit callback failure leaves the send accepted, with its audit hook and dispatch" do
    persisted = nil
    result = ModerateMessageJob.stub(:perform_later, ->(*) { raise "moderation queue down" }) do
      Messages::PostFromHuman.new(chat: @group_chat, user: @user, content: "Hey @Grok").call(on_persisted: ->(m) { persisted = m })
    end

    assert result.created?
    assert_equal persisted, result.message
    assert Message.exists?(result.message.id)
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

  test "pinned stone revisions commit with the human message and dispatch" do
    stone = Stone.publish!(chat: @group_chat, title: "Reference", html: "<!doctype html><html><body>Reference</body></html>", author: @agent, public: true)
    result = Messages::PostFromHuman.new(
      chat: @group_chat, user: @user, content: "@Grok reference", stone_revisions: [ stone.latest_revision ]
    ).call

    assert result.created?
    assert_equal [ stone.latest_revision ], result.message.reload.stone_revisions.to_a
    assert result.message.message_dispatch
  end

  test "a dispatch failure rolls back pinned stones and the draft clear too" do
    stone = Stone.publish!(chat: @group_chat, title: "Reference", html: "<!doctype html><html><body>Reference</body></html>", author: @agent, public: true)
    draft = ConversationDraft.for(chat: @group_chat, user: @user)
    draft.replace!(content: "@Grok reference", revision: 0)
    assert_no_difference [ "Message.count", "MessageStoneRevision.count", "MessageDispatch.count" ] do
      MessageDispatch.stub(:accept!, ->(**) { raise "dispatch unavailable" }) do
        assert_raises RuntimeError do
          Messages::PostFromHuman.new(
            chat: @group_chat, user: @user, content: draft.content, draft: draft, draft_revision: 1,
            stone_revisions: [ stone.latest_revision ]
          ).call
        end
      end
    end
    assert_equal [ "@Grok reference", 1 ], [ draft.reload.content, draft.revision ]
  end

  test "a resolved upload removed before claiming refuses the entire send" do
    blobs = 2.times.map do
      ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("upload"), filename: "upload.txt", content_type: "text/plain"
      )
    end
    ActiveStorage::Blob.find(blobs.last.id).purge

    assert_no_difference [ "Message.count", "ActiveStorage::Attachment.count" ] do
      result = Messages::PostFromHuman.new(
        chat: @group_chat, user: @user, content: "Stale uploads", files: blobs
      ).call
      assert result.attachment_claimed?
    end
    assert_nil blobs.first.reload.metadata["position"]
  ensure
    blobs&.each { |blob| ActiveStorage::Blob.find_by(id: blob.id)&.purge }
  end

  test "claiming merges position into freshly locked metadata rather than the resolved snapshot" do
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("upload"), filename: "upload.txt", content_type: "text/plain"
    )
    ActiveStorage::Blob.find(blob.id).update_column(:metadata, { "new_marker" => "preserved" })

    result = Messages::PostFromHuman.new(
      chat: @group_chat, user: @user, content: "Fresh metadata", files: [ blob ]
    ).call

    assert result.created?
    assert_equal "preserved", blob.reload.metadata["new_marker"]
    assert_equal 0, blob.metadata["position"]
  end

  private

  def post(content)
    Messages::PostFromHuman.new(chat: @group_chat, user: @user, content: content).call
  end

end

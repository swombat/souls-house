require "test_helper"

class ChatCreationTest < ActiveSupport::TestCase

  setup do
    @resident = agents(:research_assistant)
    @account = @resident.account
  end

  test "public creation rejects bare chats even with a model or resident IDs" do
    [ {}, { manual_responses: false }, { manual_responses: false, agents: [ @resident ] } ].each do |attributes|
      assert_no_difference [ "Chat.count", "Message.count" ] do
        assert_no_enqueued_jobs do
          error = assert_raises ActiveRecord::RecordInvalid do
            Chat.create_with_message!(
              attributes.merge(account: @account, model_id: "openai/gpt-4o"),
              message_content: "Must not persist"
            )
          end
          assert error.record.errors[:manual_responses].present?
        end
      end
    end
  end

  test "public creation requires a resident when group mode is enabled" do
    [ nil, [] ].each do |ids|
      assert_no_difference [ "Chat.count", "Message.count" ] do
        error = assert_raises ActiveRecord::RecordInvalid do
          Chat.create_with_message!({ account: @account, manual_responses: true }, agent_ids: ids)
        end
        assert error.record.errors[:agents].present?
      end
    end
  end

  test "public creation accepts explicit resident selection" do
    chat = Chat.create_with_message!(
      { account: @account, title: "Resident conversation", manual_responses: true },
      agent_ids: [ @resident.id ]
    )

    assert chat.persisted?
    assert chat.group_chat?
    assert_equal [ @resident.id ], chat.agent_ids
  end

  test "historical bare chats can be read and renamed but not forked" do
    # Ordinary low-level persistence models a pre-existing historical row;
    # public application creation must go through the group-only helpers.
    legacy = @account.chats.create!(title: "Historical", model_id: "openai/gpt-4o")
    legacy.messages.create!(role: "assistant", content: "A retained reply")

    assert_equal "A retained reply", legacy.reload.transcript_for_api.sole[:content]
    assert legacy.update(title: "Renamed history")
    assert_not legacy.reload.group_chat?

    assert_no_difference [ "Chat.count", "Message.count" ] do
      assert_raises ActiveRecord::RecordInvalid do
        legacy.fork_with_title!("Forbidden bare fork")
      end
    end
  end

end

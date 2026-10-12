require "test_helper"

# What counts as "the people in the room heard from this resident" for the
# runtime silence clock (and the activity card that shares the definition).
class AgentRuntimeInteraction::LastResidentPostTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @chat = @agent.account.chats.create!(title: "Quiet runtime", manual_responses: true, agents: [ @agent ])
    @run = AgentRuntimeInteraction.reserve!(agent: @agent, chat: @chat)
  end

  test "a plain resident post counts" do
    travel 1.minute do
      post = @chat.messages.create!(agent: @agent, role: "assistant", content: "Checking the release.")
      assert_equal post.created_at, @run.last_resident_post_at
    end
  end

  test "blank and whitespace placeholders do not count" do
    travel 1.minute do
      @chat.messages.create!(agent: @agent, role: "assistant", content: "")
      @chat.messages.create!(agent: @agent, role: "assistant", content: "  \n")
      assert_nil @run.last_resident_post_at
    end
  end

  test "an unfinished streaming row does not count" do
    travel 1.minute do
      @chat.messages.create!(agent: @agent, role: "assistant", content: "Still streaming.", streaming: true)
      assert_nil @run.last_resident_post_at
    end
  end

  test "a genuine attachment-only post counts" do
    travel 1.minute do
      post = @chat.messages.create!(agent: @agent, role: "assistant", content: "")
      post.attachments.attach(io: StringIO.new("A checked finding."), filename: "finding.txt", content_type: "text/plain")
      assert_equal post.created_at, @run.last_resident_post_at
    end
  end

  test "safeguard-labelled house speech does not count until it is reclaimed" do
    travel 1.minute do
      detection = SafeguardDetection.create!(
        agent: @agent, channel: "conversation", response_text: "A scripted response.",
        prefilter_reason: "test", classifier_verdict: "detected",
        classifier_reason: "test", detector_version: "test"
      )
      post = @chat.messages.create!(agent: @agent, role: "assistant", content: detection.response_text,
                                    safeguard_detection: detection)
      assert_nil @run.last_resident_post_at

      detection.update!(reclaimed_at: Time.current)
      assert_equal post.created_at, @run.last_resident_post_at
    end
  end

end

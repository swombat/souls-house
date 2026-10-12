require "test_helper"

class AgentRuntimeInteraction::SilencePresentationTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @chat = @agent.account.chats.create!(title: "Quiet runtime", manual_responses: true, agents: [ @agent ])
    @run = AgentRuntimeInteraction.reserve!(agent: @agent, chat: @chat)
    @run.claim_dispatch!
    @run.activity_configuration!
    @run.update!(execution_state: "running")
  end

  test "activity projection exposes server time and no post before a reply" do
    travel_to Time.current.change(usec: 0) do
      json = @run.as_chat_activity_json
      assert_equal Time.current.iso8601(3), json[:server_time]
      assert_nil json[:last_resident_post_at]
      assert json[:active]
      assert_equal "connecting", json[:reporter_health]
      assert_not json.key?(:stdout)
      assert_not json.key?(:request_text)
    end
  end

  test "an unlinked post resets the projected timestamp without exposing content" do
    travel 3.minutes do
      post = @chat.messages.create!(agent: @agent, role: "assistant", content: "I am still checking.")
      json = @run.as_chat_activity_json
      assert_equal post.created_at.iso8601(3), json[:last_resident_post_at]
      assert_nil post.runtime_interaction_id
      assert_equal 0, json[:reply_count]
      assert_not_includes json.to_json, post.content
    end
  end

  test "heartbeat freshness and terminal state are independent of silence" do
    @run.agent_runtime_attempts.create!(attempt_id: SecureRandom.uuid, number: 1, last_report_at: Time.current)
    assert_equal "live", @run.as_chat_activity_json[:reporter_health]
    travel 31.seconds do
      assert_equal "stale", @run.as_chat_activity_json[:reporter_health]
      assert @run.as_chat_activity_json[:active]
      @run.finish_execution!("completed")
      assert_not @run.as_chat_activity_json[:active]
      assert_equal "completed", @run.as_chat_activity_json[:status]
    end
  end

  test "blank assistant placeholders are not a visible resident update" do
    travel 1.minute do
      @chat.messages.create!(agent: @agent, role: "assistant", content: "")
      assert_nil @run.last_resident_post_at
    end
  end

  test "an unfinished assistant row is not a confirmed resident post" do
    travel 1.minute do
      @chat.messages.create!(agent: @agent, role: "assistant", content: "Still streaming.", streaming: true)
      assert_nil @run.last_resident_post_at
    end
  end

  test "a genuine attachment-only resident post counts" do
    travel 1.minute do
      post = @chat.messages.create!(agent: @agent, role: "assistant", content: "")
      post.attachments.attach(io: StringIO.new("A checked finding."), filename: "finding.txt", content_type: "text/plain")
      assert_equal post.created_at, @run.last_resident_post_at
    end
  end

  test "a house safeguard label does not answer the resident silence clock" do
    travel 1.minute do
      detection = SafeguardDetection.create!(
        agent: @agent, channel: "conversation", response_text: "A scripted response.",
        prefilter_reason: "test", classifier_verdict: "detected",
        classifier_reason: "test", detector_version: "test"
      )
      @chat.messages.create!(
        agent: @agent, role: "assistant", content: detection.response_text,
        safeguard_detection: detection
      )
      assert_nil @run.last_resident_post_at
    end
  end

end

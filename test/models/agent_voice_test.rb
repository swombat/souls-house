require "test_helper"
require "support/eleven_labs_voices_stub"

class AgentVoiceTest < ActiveSupport::TestCase

  include ElevenLabsVoicesStub

  setup { @agent = agents(:research_assistant) }

  test "a standard voice is accepted and a voice outside the standard list is refused" do
    with_standard_voices do
      assert @agent.update(voice_id: "std-aria")
      assert_equal "std-aria", @agent.reload.voice_id

      assert_not @agent.update(voice_id: "cloned-or-made-up")
      assert_includes @agent.errors[:voice_id], "is not one of the standard ElevenLabs voices"
      assert_equal "std-aria", @agent.reload.voice_id
    end
  end

  test "a voice the resident already has is kept when other settings change, and clearing needs no list" do
    @agent.update_column(:voice_id, "legacy-designed-voice")

    with_voice_list_unavailable do
      assert @agent.update(name: "Renamed")
      assert_equal "legacy-designed-voice", @agent.reload.voice_id

      assert @agent.update(voice_id: "")
      assert_nil @agent.reload.voice_id
    end
  end

  test "a change can't be checked while the list is unavailable, so it is refused with a reason" do
    with_voice_list_unavailable do
      assert_not @agent.update(voice_id: "std-aria")
      assert_match(/voice list is unavailable/, @agent.errors[:voice_id].to_sentence)
    end
  end

  test "an upgrade's predecessor copies a legacy voice without asking the list" do
    @agent.update_column(:voice_id, "legacy-designed-voice")

    with_voice_list_unavailable do
      predecessor = @agent.upgrade_with_predecessor!(to_model: "openai/gpt-5.2")
      assert_equal "legacy-designed-voice", predecessor.voice_id
    end
  end

end

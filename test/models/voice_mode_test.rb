require "test_helper"

class VoiceModeTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:team_account)
    @account.update!(use_system_ai_credentials: false, openai_api_key: nil)
    Setting.instance.update!(voice_mode_scope: "account_choice")
  end

  test "the site scope and the account switch decide whether the mode is offered" do
    Setting.instance.update!(voice_mode_scope: "disabled")
    @account.update!(voice_mode_enabled: true)
    assert_equal [ false, false, "site_disabled" ], status_tuple

    Setting.instance.update!(voice_mode_scope: "account_choice")
    @account.update!(voice_mode_enabled: false)
    assert_equal [ false, false, "account_disabled" ], status_tuple

    @account.update!(voice_mode_enabled: true, openai_api_key: "sk-account")
    assert_equal [ true, true, nil ], status_tuple

    Setting.instance.update!(voice_mode_scope: "enabled")
    @account.update!(voice_mode_enabled: false)
    assert_equal [ true, true, nil ], status_tuple, "enabled everywhere overrides an account's off"
  end

  test "offered without a transcription key is not available, and says which key" do
    @account.update!(voice_mode_enabled: true)
    assert_equal [ true, false, "no_transcription_key" ], status_tuple

    @account.update!(openai_api_key: "<paste your key>")
    assert_equal [ true, false, "no_transcription_key" ], status_tuple, "a placeholder is not a key"
  end

  test "the house key counts when the account falls through to house credentials" do
    @account.update!(voice_mode_enabled: true, use_system_ai_credentials: true)
    Account.stub(:system_ai_api_key, ->(provider) { provider == :openai ? "sk-house" : nil }) do
      assert_equal [ true, true, nil ], status_tuple
    end

    @account.update!(use_system_ai_credentials: false)
    Account.stub(:system_ai_api_key, "sk-house") do
      assert_equal [ true, false, "no_transcription_key" ], status_tuple, "without the fall-through the house key is not the account's"
    end
  end

  test "no account is never offered" do
    assert_equal [ false, false, "site_disabled" ], VoiceMode.status_for(nil).to_a
  end

  test "the status serialises for the page" do
    @account.update!(voice_mode_enabled: true, openai_api_key: "sk-account")
    assert_equal({ "offered" => true, "available" => true, "reason" => nil }, VoiceMode.status_for(@account).as_json)
  end

  private

  def status_tuple
    VoiceMode.status_for(@account.reload).to_a
  end

  test "speech text passes a short reply through and cuts a long one at a sentence end, saying so" do
    short = Message.new(role: "assistant", content: "Two **short** sentences. With [a link](https://example.com).")
    assert_equal "Two short sentences. With a link.", VoiceMode.speech_text(short)

    sentence = "This sentence is about forty-five characters. "
    long = Message.new(role: "assistant", content: sentence * 40)
    spoken = VoiceMode.speech_text(long)
    assert_operator spoken.length, :<=, VoiceMode::SPEECH_CAP + VoiceMode::SPEECH_TRUNCATION_NOTE.length + 1
    assert spoken.end_with?("characters. #{VoiceMode::SPEECH_TRUNCATION_NOTE}"), spoken.last(80)

    unbroken = Message.new(role: "assistant", content: "word " * 400)
    assert unbroken.content_for_speech.length > VoiceMode::SPEECH_CAP
    assert VoiceMode.speech_text(unbroken).end_with?("word… #{VoiceMode::SPEECH_TRUNCATION_NOTE}")
  end

  test "a reply resumed after a barge-in starts at the sentence it had reached (#758)" do
    message = Message.new(role: "assistant", content: "First one here. Second sentence is this one. Third and last.")
    assert_equal message.content_for_speech, VoiceMode.speech_text(message, from_seconds: nil)
    assert_equal message.content_for_speech, VoiceMode.speech_text(message, from_seconds: 0)
    # 15 chars a second: 1 s is still inside the first sentence, 2 s inside the second.
    assert_equal message.content_for_speech, VoiceMode.speech_text(message, from_seconds: 1)
    assert_equal "Second sentence is this one. Third and last.", VoiceMode.speech_text(message, from_seconds: 2)
    assert_equal "Third and last.", VoiceMode.speech_text(message, from_seconds: 3.5)
    # An overshoot still says the last sentence rather than nothing.
    assert_equal "Third and last.", VoiceMode.speech_text(message, from_seconds: 600)
    unbroken = Message.new(role: "assistant", content: "no sentence end at all here")
    assert_equal "no sentence end at all here", VoiceMode.speech_text(unbroken, from_seconds: 30)
  end

  test "a spoken turn has no addressee in a room where every message wakes its resident" do
    chat = @account.chats.create!(model_id: "openrouter/auto", manual_responses: false)
    assert_nil VoiceMode.addressee(chat, "Anyone, hello")
  end

end

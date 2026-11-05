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
    assert_equal [ false, false, "site_disabled" ], VoiceMode.status_for(nil).to_a.first(3)
  end

  test "the status serialises for the page" do
    @account.update!(voice_mode_enabled: true, openai_api_key: "sk-account")
    assert_equal({ "offered" => true, "available" => true, "reason" => nil, "speech_engine" => "phonon" },
      VoiceMode.status_for(@account).as_json)
  end

  # The open panel stops reading when this changes (SpeechEngine, jEDyze).
  test "the status carries the account's voice engine" do
    @account.update!(voice_mode_enabled: true, speech_engine: "elevenlabs")
    Setting.instance.update!(speech_engine_scope: "account_choice")
    assert_equal "elevenlabs", VoiceMode.status_for(@account.reload).speech_engine
    Setting.instance.update!(speech_engine_scope: "disabled")
    assert_equal "phonon", VoiceMode.status_for(@account.reload).speech_engine
  end

  private

  def status_tuple
    VoiceMode.status_for(@account.reload).to_a.first(3)
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

  test "a spoken turn has no addressee in a room where every message wakes its resident" do
    chat = @account.chats.create!(model_id: "openrouter/auto", manual_responses: false)
    assert_nil VoiceMode.addressee(chat, "Anyone, hello")
  end

  # #747: Daniel in a fresh chat, "So now I'm going to say, hey Lume, what's up?", woke nobody.
  test "in a fresh chat a resident named mid-sentence is the addressee" do
    lume, mira, chat = lume_and_mira_chat
    assert_equal lume, VoiceMode.addressee(chat, "So now I'm going to say, hey Lume, what's up?")
    assert_equal mira, VoiceMode.addressee(chat, "I think this is one for Mira, really")
  end

  test "in a fresh chat two different names route nobody, and no name goes to the first listed resident" do
    lume, _mira, chat = lume_and_mira_chat
    assert_nil VoiceMode.addressee(chat, "So I was telling Mira that Lume had a point")
    assert_equal lume, VoiceMode.addressee(chat, "What's on today?")
  end

  test "a turn that opens with a name still wins, and a name inside a word is not a name" do
    lume, mira, chat = lume_and_mira_chat
    reply_from(chat, lume)
    assert_equal mira, VoiceMode.addressee(chat, "Hey Mira, what do you think Lume meant?")
    assert_equal lume, VoiceMode.addressee(chat, "Tell me about Miranda"), "Miranda is not Mira: continues with the last speaker"
  end

  test "after a reply, a short turn naming one resident goes to them; a long one continues with the last speaker" do
    lume, mira, chat = lume_and_mira_chat
    reply_from(chat, lume)
    assert_equal mira, VoiceMode.addressee(chat, "So now I'm going to say, hey Mira, what's up?")
    assert_equal lume, VoiceMode.addressee(chat, "Thanks, that helps")

    long = "#{'and then we walked a bit further along the beach ' * 4}and Mira said it was cold"
    assert_operator long.split.size, :>, VoiceMode::SHORT_TURN_WORDS
    assert_equal lume, VoiceMode.addressee(chat, long)
  end

  test "two names after a reply do not pick one by guess: the turn continues with the last speaker" do
    lume, _mira, chat = lume_and_mira_chat
    reply_from(chat, lume)
    assert_equal lume, VoiceMode.addressee(chat, "So I told Mira what Lume said")
  end

  def lume_and_mira_chat
    lume = agents(:research_assistant)
    mira = agents(:code_reviewer)
    lume.update_columns(name: "Lume", account_id: @account.id)
    mira.update_columns(name: "Mira", account_id: @account.id)
    chat = @account.chats.create!(model_id: "openrouter/auto", manual_responses: true, agents: [ lume, mira ])
    [ lume, mira, chat ]
  end

  def reply_from(chat, agent)
    chat.messages.create!(role: "assistant", agent:, content: "Here.")
  end

end

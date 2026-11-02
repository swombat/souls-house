require "test_helper"

class VoiceMode::TranscriptionSecretTest < ActiveSupport::TestCase

  # Cassettes recorded against api.openai.com on 2026-11-02: a successful mint
  # with the house key, a session OpenAI refused for a keyword with "<" in it
  # followed by the retry without keywords, and a refused key.

  setup do
    @account = accounts(:team_account)
  end

  # The glossary already refuses < and > in a term; the filter in keywords_for
  # is there so a term that slipped in some other way can't cost the session.
  test "the glossary's terms become keywords" do
    TranscriptionGlossary.new(@account).add!("GrantTree", by: users(:user_1))

    keywords = VoiceMode::TranscriptionSecret.keywords_for(@account)
    assert_includes keywords, "GrantTree"
    assert_operator keywords.size, :<=, VoiceMode::TranscriptionSecret::MAX_KEYWORDS
  end

  test "the session is a transcription session the page's detector drives" do
    config = VoiceMode::TranscriptionSecret.session_config(keywords: [ "GrantTree" ])
    input = config[:audio][:input]
    assert_equal "transcription", config[:type]
    assert_equal({ type: "audio/pcm", rate: 24_000 }, input[:format])
    assert_equal "gpt-live-transcribe", input[:transcription][:model]
    assert_equal [ "GrantTree" ], input[:transcription][:keywords]
    assert input.key?(:turn_detection)
    assert_nil input[:turn_detection], "no server turn detection: the page commits each turn"
    assert_not VoiceMode::TranscriptionSecret.session_config[:audio][:input][:transcription].key?(:keywords)
  end

  test "mints a short-lived secret with the account's key" do
    @account.update!(openai_api_key: "sk-test-voice-mode", use_system_ai_credentials: false)

    result = VCR.use_cassette("voice_mode_transcription_secret") do
      VoiceMode::TranscriptionSecret.new(@account, keywords: [ "GrantTree" ]).mint
    end

    assert result.client_secret.start_with?("ek_")
    assert_kind_of Integer, result.expires_at
    assert_equal "gpt-live-transcribe", result.model
    assert_equal "wss://api.openai.com/v1/realtime?intent=transcription", result.socket_url
    assert_equal 24_000, result.sample_rate
  end

  test "a session refused for its keywords is asked for again without them" do
    @account.update!(openai_api_key: "sk-test-voice-mode", use_system_ai_credentials: false)

    result = VCR.use_cassette("voice_mode_transcription_secret_keyword_retry") do
      VoiceMode::TranscriptionSecret.new(@account, keywords: [ "a <b> term" ]).mint
    end

    assert result.client_secret.start_with?("ek_")
  end

  test "a refused key says so" do
    @account.update!(openai_api_key: "sk-not-a-real-key", use_system_ai_credentials: false)

    error = VCR.use_cassette("voice_mode_transcription_secret_bad_key") do
      assert_raises(VoiceMode::TranscriptionSecret::Error) do
        VoiceMode::TranscriptionSecret.new(@account, keywords: []).mint
      end
    end
    assert_equal "The OpenAI API key was refused.", error.message
  end

  test "no key is refused before anything is asked of OpenAI" do
    @account.update!(openai_api_key: nil, use_system_ai_credentials: false)

    error = assert_raises(VoiceMode::TranscriptionSecret::Error) do
      VoiceMode::TranscriptionSecret.new(@account).mint
    end
    assert_match "No OpenAI API key", error.message
  end

end

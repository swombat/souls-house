require "test_helper"
require "webmock/minitest"

# Listen's stored audio under a resident's delivery (eOyXXJ): the request
# carries the delivery, the gain is applied, and the audio is marked with the
# voice and delivery it was made with, read once per render.
class GenerateVoiceJobTest < ActiveJob::TestCase

  URL = "https://api.elevenlabs.io/v1/text-to-speech/voice-123"
  TAKE_03 = {
    "model_id" => "eleven_multilingual_v2", "speed" => 0.75, "stability" => 0.75,
    "similarity_boost" => 0.85, "style" => 0.15, "use_speaker_boost" => true, "gain_db" => 10.0
  }.freeze

  setup do
    Setting.instance.update!(allow_chats: true, speech_engine_scope: "account_choice")
    @account = accounts(:personal_account)
    @account.update!(speech_engine: "elevenlabs", eleven_labs_api_key: "account-eleven-key")
    @agent = @account.agents.create!(name: "Speaker", system_prompt: "Test", runtime: "external")
    @agent.update_column(:voice_id, "voice-123")
    @chat = @account.chats.create!(model_id: "openrouter/auto", title: "Listen")
    @chat.agents << @agent
    @reply = @chat.messages.create!(role: "assistant", agent: @agent, content: "Hello there.", suppress_automatic_dispatch: true)
  end

  def render_with(gains = [], tempos = [])
    bodies = []
    stub_request(:post, URL).to_return { |request| bodies << JSON.parse(request.body); { status: 200, body: "ID3raw" } }
    AudioGain.stub(:apply, ->(audio, gain, tempo: nil) { gains << gain; tempos << tempo; gain.to_f.zero? && tempo.nil? ? audio : "ID3gained" }) do
      yield if block_given?
      GenerateVoiceJob.perform_now(@reply)
    end
    bodies
  end

  test "with no delivery, Listen sends today's body and stores audio marked default" do
    gains = []
    bodies = render_with(gains)

    assert_equal "eleven_v3", bodies.sole["model_id"]
    assert_equal 1.0, bodies.sole.dig("voice_settings", "speed")
    assert_equal [ 0.0 ], gains
    assert_equal "ID3raw", @reply.reload.voice_audio.download
    assert_equal "voice-123:default", @reply.voice_audio.blob.metadata["voice_digest"]
    assert @reply.voice_audio_current?
  end

  test "with take 03, Listen sends multilingual_v2 at 0.75 and stores the gained audio" do
    @agent.update!(voice_delivery: TAKE_03)
    gains = []
    bodies = render_with(gains)

    assert_equal "eleven_multilingual_v2", bodies.sole["model_id"]
    assert_equal 0.75, bodies.sole.dig("voice_settings", "speed")
    assert_equal [ 10.0 ], gains
    assert_equal "ID3gained", @reply.reload.voice_audio.download
    assert @reply.voice_audio_current?
    assert @reply.voice_audio_url
  end

  test "a delivery changed while ElevenLabs works leaves the audio marked with the one it was made under" do
    @agent.update!(voice_delivery: TAKE_03)
    made_under = @agent.speech_delivery.digest("voice-123")
    stub_request(:post, URL).to_return do
      Agent.find(@agent.id).update!(voice_delivery: TAKE_03.merge("speed" => 0.9))
      { status: 200, body: "ID3raw" }
    end
    AudioGain.stub(:apply, ->(audio, _gain, tempo: nil) { audio }) { GenerateVoiceJob.perform_now(@reply) }

    assert_equal made_under, @reply.reload.voice_audio.blob.metadata["voice_digest"]
    assert_not @reply.voice_audio_current?
    assert_nil @reply.voice_audio_url
  end

  test "audio already made under the current delivery is not made again" do
    render_with
    WebMock::RequestRegistry.instance.reset!
    stub = stub_request(:post, URL)
    GenerateVoiceJob.perform_now(@reply.reload)
    assert_not_requested stub
  end

  test "audio from before delivery existed is current only under the defaults" do
    @reply.voice_audio.attach(io: StringIO.new("ID3legacy"), filename: "legacy.mp3", content_type: "audio/mpeg")
    assert @reply.reload.voice_audio_current?

    @agent.update!(voice_delivery: TAKE_03)
    assert_not @reply.reload.voice_audio_current?
  end

  test "clearing the delivery back to nil does not accept audio made under the custom one" do
    @agent.update!(voice_delivery: TAKE_03)
    render_with
    assert @reply.reload.voice_audio_current?

    @agent.update!(voice_delivery: nil)
    assert_not @reply.reload.voice_audio_current?
    bodies = render_with
    assert_equal "eleven_v3", bodies.sole["model_id"]
    assert @reply.reload.voice_audio_current?
  end

  test "two Listen presses on one message are one render at a time" do
    assert_equal 1, GenerateVoiceJob.concurrency_limit
    assert_equal GenerateVoiceJob.new(@reply).concurrency_key, GenerateVoiceJob.new(@reply).concurrency_key
  end

  test "with a tempo, Listen sends ElevenLabs' speed and slows the stored audio afterwards" do
    @agent.update!(voice_delivery: TAKE_03.merge("speed" => 0.7, "tempo" => 0.93))
    gains = []
    tempos = []
    bodies = render_with(gains, tempos)

    assert_equal 0.7, bodies.sole.dig("voice_settings", "speed")
    assert_not bodies.sole.key?("tempo")
    assert_not bodies.sole["voice_settings"].key?("tempo")
    assert_equal [ 0.93 ], tempos
    assert_equal "ID3gained", @reply.reload.voice_audio.download
  end

  test "with no tempo set, Listen passes none" do
    @agent.update!(voice_delivery: TAKE_03)
    tempos = []
    render_with([], tempos)
    assert_equal [ nil ], tempos
  end

end

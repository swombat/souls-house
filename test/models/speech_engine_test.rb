require "test_helper"

# Which engine reads a resident aloud (SpeechEngine, jEDyze): the site scope,
# the account's choice, its own ElevenLabs key, the resident's plan and its
# ElevenLabs voice, and that nothing falls back to the other engine or to the
# house's ElevenLabs credential.
class SpeechEngineTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @account = @agent.account
    @account.update!(speech_engine: "phonon", eleven_labs_api_key: nil)
    @agent.update_column(:voice_id, "std-aria")
    Setting.instance.update!(speech_engine_scope: "disabled")
  end

  def scope(value) = Setting.instance.update!(speech_engine_scope: value)
  def engine = SpeechEngine.for(@account.reload, @agent)

  def plan(tier, state: "active", source: "stripe")
    ResidentEntitlement.where(agent: @agent).delete_all
    ResidentEntitlement.create!(agent: @agent, account: @account, source:, state:, tier:)
  end

  test "Phonon is the default: a new site and a new account read every resident with Phonon" do
    assert_equal "disabled", Setting.new.speech_engine_scope
    assert_equal "phonon", Account.new.speech_engine
    assert_equal({ "engine" => "phonon", "available" => true, "reason" => nil, "message" => nil }, engine.as_json)
  end

  test "the site scope decides whether the account's choice counts" do
    @account.update!(speech_engine: "elevenlabs", eleven_labs_api_key: "acct-key")

    scope("disabled")
    assert_predicate engine, :phonon?, "off: Phonon whatever the account chose"

    scope("account_choice")
    assert_predicate engine, :elevenlabs?, "account choice: the account's ElevenLabs"
    @account.update!(speech_engine: "phonon")
    assert_predicate engine, :phonon?, "account choice: the account's Phonon"

    scope("enabled")
    assert_predicate engine, :elevenlabs?, "everyone: ElevenLabs whatever the account chose"
  end

  test "ElevenLabs without the account's own key is an error, never Phonon and never the house key" do
    scope("account_choice")
    @account.update!(speech_engine: "elevenlabs")

    ElevenLabsTts.stub(:api_key, "house-key") do
      status = engine
      assert_predicate status, :elevenlabs?
      assert_not status.available
      assert_equal "no_eleven_labs_key", status.reason
      assert_match(/no ElevenLabs key of its own/, status.message)
    end
  end

  test "ElevenLabs with no ElevenLabs voice for the resident says so" do
    scope("enabled")
    @account.update!(eleven_labs_api_key: "acct-key")
    @agent.update_column(:voice_id, nil)

    assert_predicate engine, :elevenlabs?
    assert_equal "no_eleven_labs_voice", engine.reason
  end

  test "ElevenLabs reads only Life and Work residents and residents on the house; Conversation speaks Phonon" do
    scope("account_choice")
    @account.update!(speech_engine: "elevenlabs", eleven_labs_api_key: "acct-key")

    assert_predicate engine, :elevenlabs?, "on the house (no plan)"

    %w[life work].each do |tier|
      plan(tier)
      assert_predicate engine, :elevenlabs?, tier
      assert engine.available
    end

    plan("conversation")
    assert_predicate engine, :phonon?, "a Conversation resident is read by Phonon, by rule"
    assert engine.available

    plan("life", state: "held")
    assert_predicate engine, :phonon?, "a lapsed plan is not in force"

    plan(nil, state: "complimentary", source: "complimentary")
    assert_predicate engine, :elevenlabs?, "complimentary counts as the house"
  end

  test "a paid birth waiting for its billing link is not taken for a resident on the house" do
    scope("enabled")
    @account.update!(eleven_labs_api_key: "acct-key")
    ResidentBirthOrder.create!(account: @account, creator: users(:user_1), tier: "conversation", state: "born", agent: @agent)

    assert_predicate engine, :phonon?
  end

  test "the account's key is stored encrypted, kept out of the account's JSON and out of residents' environment" do
    @account.update!(eleven_labs_api_key: "  acct-secret-key  ")

    assert_equal "acct-secret-key", @account.reload.eleven_labs_api_key
    raw = Account.connection.select_value("SELECT eleven_labs_api_key FROM accounts WHERE id = #{@account.id}")
    assert_not_includes raw.to_s, "acct-secret-key"
    assert_not_includes @account.as_json.keys, "eleven_labs_api_key"
    assert_not_includes @account.ai_provider_keys.values, "acct-secret-key"
  end

  test "the Phonon voice is the resident's own choice or the catalogue default, and must be a catalogue voice" do
    assert_equal PhononVoices.default.id, SpeechEngine.phonon_voice_for(@agent)
    assert_equal "Delia", PhononVoices.default.name

    hugh = PhononVoices.catalogue.find { |voice| voice.name == "Hugh" }
    assert @agent.update(phonon_voice: hugh.id)
    assert_equal hugh.id, SpeechEngine.phonon_voice_for(@agent.reload)

    assert_not @agent.update(phonon_voice: "made-up")
    assert_includes @agent.errors[:phonon_voice], "is not one of the Phonon voices"
    assert @agent.update(phonon_voice: "")
    assert_nil @agent.reload.phonon_voice
  end

  test "the catalogue is the 37 English voices, every one served from the pinned assets" do
    assert_equal 37, PhononVoices.catalogue.size
    manifest = JSON.parse(Rails.root.join("config/phonon_assets.json").read).fetch("files")
    served = manifest.map { |file| file["path"] }
    PhononVoices.catalogue.each { |voice| assert_includes served, "voices/#{voice.id}.safetensors", voice.name }
    assert manifest.all? { |file| file["sha256"].match?(/\A\h{64}\z/) && file["revision"].match?(/\A\h{40}\z/) }
    assert manifest.none? { |file| file["repo"].include?("40m") }, "the 40M models are CC BY-NC: never served"
  end

end

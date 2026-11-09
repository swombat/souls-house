require "test_helper"
require "support/eleven_labs_voices_stub"

class Agents::VoicesControllerTest < ActionDispatch::IntegrationTest

  include ElevenLabsVoicesStub

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    Setting.instance.update!(allow_agents: true)
    sign_in(@user)
  end

  test "a person overrides the resident's voice from Appearance, audited as them" do
    @agent.update_column(:voice_id, "std-aria")

    with_standard_voices do
      patch voice_account_agent_path(@account, @agent), params: { voice_id: "std-brian" }, headers: { "X-Inertia" => true }
    end

    assert_redirected_to edit_account_agent_path(@account, @agent, tab: "appearance")
    assert_equal "std-brian", @agent.reload.voice_id
    log = AuditLog.where(action: "set_agent_voice", auditable: @agent).last
    assert_equal @user, log.user
    assert_equal "std-brian", log.data["voice_id"]
  end

  test "a voice outside the standard list is refused and nothing changes" do
    @agent.update_column(:voice_id, "legacy-designed-voice")

    with_standard_voices do
      patch voice_account_agent_path(@account, @agent), params: { voice_id: "made-up" }, as: :json
    end

    assert_response :unprocessable_entity
    assert_match(/standard ElevenLabs voices/, response.parsed_body["errors"].first)
    assert_equal "legacy-designed-voice", @agent.reload.voice_id
    assert_not AuditLog.exists?(action: "set_agent_voice", auditable: @agent)
  end

  test "a person can remove the voice" do
    @agent.update_column(:voice_id, "std-aria")

    patch voice_account_agent_path(@account, @agent), params: { voice_id: "" }, as: :json

    assert_response :success
    assert_nil @agent.reload.voice_id
  end

  test "the preview is the resident saying one line through the message speech path" do
    calls = []
    fake = ->(text, voice_id:, api_key: nil) { calls << [ text, voice_id, api_key ]; "ID3-audio" }

    with_standard_voices do
      ElevenLabsTts.stub(:synthesize, fake) do
        get voice_preview_account_agent_path(@account, @agent, voice_id: "std-brian")
      end
    end

    assert_response :success
    assert_equal "audio/mpeg", response.media_type
    assert_equal "ID3-audio", response.body
    assert_equal [ [ Agents::VoicesController.preview_text(@agent.name), "std-brian", nil ] ], calls
  end

  test "no preview for a voice outside the standard list, and a provider failure is a 503" do
    with_standard_voices do
      get voice_preview_account_agent_path(@account, @agent, voice_id: "cloned-1")
      assert_response :not_found

      ElevenLabsTts.stub(:synthesize, ->(*, **) { raise ElevenLabsTts::Error, "rate limited" }) do
        get voice_preview_account_agent_path(@account, @agent, voice_id: "std-aria")
      end
      assert_response :service_unavailable
    end
  end

  test "the Appearance tab draws without asking the provider, and the picker's list comes from its own route" do
    get edit_account_agent_path(@account, @agent, tab: "appearance")
    assert_response :success
    voice = inertia_shared_props["voice"]
    assert_equal voices_account_agent_path(@account, @agent), voice["voices_path"]
    assert_equal voice_account_agent_path(@account, @agent), voice["update_path"]
    assert_nil voice["voices"]

    with_standard_voices { get voices_account_agent_path(@account, @agent), as: :json }
    assert_response :success
    assert_equal %w[std-aria std-brian], response.parsed_body["voices"].map { |v| v["voice_id"] }

    with_voice_list_unavailable { get voices_account_agent_path(@account, @agent), as: :json }
    assert_response :success
    assert_equal true, response.parsed_body["unavailable"]
  end


  # The Phonon voice (jEDyze): its own choice beside the ElevenLabs one.
  test "a person sets the resident's Phonon voice without touching its ElevenLabs voice" do
    @agent.update_column(:voice_id, "std-aria")
    hugh = PhononVoices.catalogue.find { |voice| voice.name == "Hugh" }

    patch voice_account_agent_path(@account, @agent), params: { phonon_voice: hugh.id }, headers: { "X-Inertia" => true }

    assert_redirected_to edit_account_agent_path(@account, @agent, tab: "appearance")
    assert_equal [ hugh.id, "std-aria" ], @agent.reload.values_at(:phonon_voice, :voice_id)
    assert_equal hugh.id, AuditLog.where(action: "set_agent_voice", auditable: @agent).last.data["phonon_voice"]

    patch voice_account_agent_path(@account, @agent), params: { phonon_voice: "made-up" }, as: :json
    assert_response :unprocessable_entity
    assert_equal hugh.id, @agent.reload.phonon_voice

    patch voice_account_agent_path(@account, @agent), params: { phonon_voice: "" }, as: :json
    assert_response :success
    assert_nil @agent.reload.phonon_voice
  end

  test "the picker lists the account's own voices as their own group, without the key" do
    @account.update!(eleven_labs_api_key: "acct-secret-key")

    with_standard_voices do
      with_library_voices do
        get voices_account_agent_path(@account, @agent), as: :json
      end
    end

    assert_response :success
    assert_equal %w[std-aria std-brian], response.parsed_body["voices"].map { |v| v["voice_id"] }
    assert_equal %w[own-janis], response.parsed_body["library_voices"].map { |v| v["voice_id"] }
    assert_not_includes response.body, "acct-secret-key"
  end

  test "an unreadable library leaves the standard voices showing, and the other way round" do
    with_standard_voices do
      ElevenLabsVoices.stub(:library, ->(_) { raise ElevenLabsVoices::Unavailable, "401" }) do
        get voices_account_agent_path(@account, @agent), as: :json
      end
    end
    assert_equal 2, response.parsed_body["voices"].size
    assert response.parsed_body["library_unavailable"]

    with_voice_list_unavailable do
      with_library_voices do
        get voices_account_agent_path(@account, @agent), as: :json
      end
    end
    assert response.parsed_body["unavailable"]
    assert_equal %w[own-janis], response.parsed_body["library_voices"].map { |v| v["voice_id"] }
  end

  test "an own voice is chosen and previewed through the account's key" do
    @account.update!(eleven_labs_api_key: "acct-key")
    calls = []
    fake = ->(text, voice_id:, api_key: nil) { calls << [ voice_id, api_key ]; "ID3-own" }

    with_standard_voices do
      with_library_voices do
        patch voice_account_agent_path(@account, @agent), params: { voice_id: "own-janis" }, as: :json
        assert_response :success
        ElevenLabsTts.stub(:synthesize, fake) do
          get voice_preview_account_agent_path(@account, @agent, voice_id: "own-janis")
        end
      end
    end

    assert_equal "own-janis", @agent.reload.voice_id
    assert_response :success
    assert_equal [ [ "own-janis", "acct-key" ] ], calls
  end

  test "a standard-list outage is a 503 for a voice the own library doesn't have, not a 404" do
    @account.update!(eleven_labs_api_key: "acct-key")

    with_voice_list_unavailable do
      with_library_voices do
        get voice_preview_account_agent_path(@account, @agent, voice_id: "std-aria")
      end
    end

    assert_response :service_unavailable
  end

  test "an own voice's cached preview is never served to another account" do
    store = ActiveSupport::Cache::MemoryStore.new
    other_account = accounts(:team_account)
    other_agent = agents(:other_account_agent)
    other_agent.update_column(:name, @agent.name) # same line, same digest: only the account scope tells them apart
    @account.update!(eleven_labs_api_key: "key-one")
    other_account.update!(eleven_labs_api_key: "key-two")
    rendered = []
    fake = ->(_text, voice_id:, api_key: nil) { rendered << api_key; "audio-#{api_key}" }

    Rails.stub(:cache, store) do
      with_standard_voices do
        with_library_voices do
          ElevenLabsTts.stub(:synthesize, fake) do
            get voice_preview_account_agent_path(@account, @agent, voice_id: "own-janis")
            assert_equal "audio-key-one", response.body

            get voice_preview_account_agent_path(other_account, other_agent, voice_id: "own-janis")
            assert_equal "audio-key-two", response.body
          end
        end
        ElevenLabsVoices.stub(:library, ->(_) { [] }) do
          get voice_preview_account_agent_path(other_account, other_agent, voice_id: "own-janis")
          assert_response :not_found, "a voice not in this account's library is not served, cached or not"
        end
      end
    end

    assert_equal %w[key-one key-two], rendered
  end

end

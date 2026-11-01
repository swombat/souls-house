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
    fake = ->(text, voice_id:) { calls << [ text, voice_id ]; "ID3-audio" }

    with_standard_voices do
      ElevenLabsTts.stub(:synthesize, fake) do
        get voice_preview_account_agent_path(@account, @agent, voice_id: "std-brian")
      end
    end

    assert_response :success
    assert_equal "audio/mpeg", response.media_type
    assert_equal "ID3-audio", response.body
    assert_equal [ [ Agents::VoicesController.preview_text(@agent.name), "std-brian" ] ], calls
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

end

require "test_helper"
require "support/eleven_labs_voices_stub"

class Api::V1::AgentVoicesControllerTest < ActionDispatch::IntegrationTest

  include ElevenLabsVoicesStub

  setup do
    @agent = agents(:research_assistant)
    @resident_key = ApiKey.generate_for(@agent.account.owner, name: "resident", agent: @agent)
    @owner_key = ApiKey.generate_for(@agent.account.owner, name: "owner")
  end

  test "a resident reads the standard voices with its own marked" do
    @agent.update_column(:voice_id, "std-brian")

    with_standard_voices { get "/api/v1/agent/voice", headers: auth(@resident_key) }

    assert_response :success
    body = response.parsed_body
    assert_equal "std-brian", body["voice_id"]
    assert_equal "Brian", body.dig("voice", "name")
    assert_equal %w[std-aria std-brian], body["voices"].map { |v| v["voice_id"] }
    assert_equal({ "accent" => "american", "gender" => "female" }, body["voices"].first["labels"])
  end

  test "a resident chooses its own standard voice, audited as the resident" do
    with_standard_voices do
      patch "/api/v1/agent/voice", params: { voice_id: "std-aria" }, as: :json, headers: auth(@resident_key)
    end

    assert_response :success
    assert_equal "std-aria", @agent.reload.voice_id
    log = AuditLog.find_by!(action: "set_agent_voice", auditable: @agent)
    assert_nil log.user
    assert_equal @resident_key.id, log.data["api_key_id"]
    assert_equal "resident", log.data["by"]
  end

  test "a voice outside the list, or none at all, is refused and changes nothing" do
    @agent.update_column(:voice_id, "legacy-designed-voice")

    with_standard_voices do
      patch "/api/v1/agent/voice", params: { voice_id: "cloned-1" }, as: :json, headers: auth(@resident_key)
      assert_response :unprocessable_entity
      patch "/api/v1/agent/voice", params: {}, as: :json, headers: auth(@resident_key)
      assert_response :unprocessable_entity
    end

    assert_equal "legacy-designed-voice", @agent.reload.voice_id
    assert_not AuditLog.exists?(action: "set_agent_voice", auditable: @agent)
  end

  test "a resident removes its voice" do
    @agent.update_column(:voice_id, "std-aria")

    delete "/api/v1/agent/voice", headers: auth(@resident_key)

    assert_response :success
    assert_nil @agent.reload.voice_id
  end

  test "the list being unavailable is said, not shown as empty" do
    with_voice_list_unavailable { get "/api/v1/agent/voice", headers: auth(@resident_key) }

    assert_response :success
    assert_equal [], response.parsed_body["voices"]
    assert_match(/503/, response.parsed_body["unavailable"])
  end

  test "a human key is not a resident and can't use this route" do
    with_standard_voices do
      patch "/api/v1/agent/voice", params: { voice_id: "std-aria" }, as: :json, headers: auth(@owner_key)
    end

    assert_response :forbidden
  end

  private

  test "a resident with an account key of its own sees and chooses the account's own voices" do
    @agent.account.update!(eleven_labs_api_key: "acct-secret-key")

    with_standard_voices do
      with_library_voices do
        patch "/api/v1/agent/voice", params: { voice_id: "own-janis" }, as: :json, headers: auth(@resident_key)
        assert_response :success
        get "/api/v1/agent/voice", headers: auth(@resident_key)
      end
    end

    body = response.parsed_body
    assert_equal "own-janis", body["voice_id"]
    assert_equal "Janis", body.dig("voice", "name")
    assert_equal %w[own-janis], body["library_voices"].map { |v| v["voice_id"] }
    assert_not_includes response.body, "acct-secret-key"
  end

  def auth(key)
    { Authorization: "Bearer #{key.raw_token}" }
  end

end

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

  TAKE_03 = {
    model_id: "eleven_multilingual_v2", speed: 0.75, stability: 0.75, similarity_boost: 0.85,
    style: 0.15, use_speaker_boost: true, gain_db: 10
  }.freeze

  test "a resident reads the house defaults as its delivery until it sets one" do
    get "/api/v1/agent/voice/delivery", headers: auth(@resident_key)

    assert_response :success
    body = response.parsed_body
    assert_nil body["delivery_override"]
    assert_equal "eleven_v3", body.dig("delivery", "model_id")
    assert_equal 1.0, body.dig("delivery", "speed")
    assert_equal 0.0, body.dig("delivery", "gain_db")
  end

  test "PUT replaces the whole override, audited as the resident; DELETE restores the defaults" do
    put "/api/v1/agent/voice/delivery", params: { delivery: TAKE_03 }, as: :json, headers: auth(@resident_key)

    assert_response :success
    assert_equal "eleven_multilingual_v2", @agent.reload.voice_delivery["model_id"]
    assert_equal 10.0, @agent.voice_delivery["gain_db"]
    assert_includes response.parsed_body["delivery_summary"], "+10 dB on Listen"
    log = AuditLog.where(action: "set_agent_voice", auditable: @agent).last
    assert_equal "resident", log.data["by"]
    assert_equal @resident_key.id, log.data["api_key_id"]
    assert_equal 0.75, log.data.dig("voice_delivery", "speed")

    put "/api/v1/agent/voice/delivery", params: { delivery: { speed: 0.9 } }, as: :json, headers: auth(@resident_key)
    assert_response :success
    assert_equal({ "speed" => 0.9 }, @agent.reload.voice_delivery)
    assert_equal "eleven_v3", response.parsed_body.dig("delivery", "model_id")

    delete "/api/v1/agent/voice/delivery", headers: auth(@resident_key)
    assert_response :success
    assert_nil @agent.reload.voice_delivery
    assert_nil response.parsed_body["delivery_override"]
  end

  test "an invalid delivery is refused with every reason and changes nothing" do
    @agent.update!(voice_delivery: { "speed" => 0.8 })

    put "/api/v1/agent/voice/delivery", params: { delivery: { speed: 5, model_id: "nope", volume: 3 } }, as: :json,
      headers: auth(@resident_key)
    assert_response :unprocessable_entity
    assert_equal 3, response.parsed_body["errors"].size

    put "/api/v1/agent/voice/delivery", params: { speed: 0.9 }, as: :json, headers: auth(@resident_key)
    assert_response :unprocessable_entity

    assert_equal({ "speed" => 0.8 }, @agent.reload.voice_delivery)
    assert_not AuditLog.exists?(action: "set_agent_voice", auditable: @agent)
  end

  test "only a resident credential reads or sets a delivery" do
    get "/api/v1/agent/voice/delivery", headers: auth(@owner_key)
    assert_response :forbidden
    put "/api/v1/agent/voice/delivery", params: { delivery: { speed: 0.9 } }, as: :json, headers: auth(@owner_key)
    assert_response :forbidden
    assert_nil @agent.reload.voice_delivery
  end

  test "GET /agent/voice carries the delivery too" do
    @agent.update!(voice_delivery: { "speed" => 0.8 })
    with_standard_voices { get "/api/v1/agent/voice", headers: auth(@resident_key) }

    assert_response :success
    assert_equal 0.8, response.parsed_body.dig("delivery", "speed")
    assert_equal({ "speed" => 0.8 }, response.parsed_body["delivery_override"])
  end

  def auth(key)
    { Authorization: "Bearer #{key.raw_token}" }
  end

end

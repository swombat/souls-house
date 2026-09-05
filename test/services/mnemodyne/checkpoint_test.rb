require "test_helper"

class Mnemodyne::CheckpointTest < ActiveSupport::TestCase

  setup do
    agent = agents(:research_assistant)
    agent.update_columns(runtime: "external", uuid: SecureRandom.uuid)
    @vault = agent.create_memory_vault!
    @node = @vault.nodes.create!(node_type: "memory", content: "Keep me", source_uris: [ "identity://journal.md" ])
    @envelope = Mnemodyne::Checkpoint.export(@vault)
  end

  test "exports a digest and provenance without embedding bodies or credentials" do
    payload = @envelope.fetch("payload")
    assert_equal @vault.agent.uuid, payload["resident_uuid"]
    assert_equal @node.id, payload["nodes"].first["id"]
    assert_equal Digest::SHA256.hexdigest(JSON.generate(payload)), @envelope["sha256"]
    assert_not payload["nodes"].first.key?("embedding")
    assert_not_includes @envelope.to_json, "outbound_api_token"
  end

  test "replacement requires suspension and restores stable IDs" do
    assert_raises(Mnemodyne::Checkpoint::Invalid) { Mnemodyne::Checkpoint.import(@vault, @envelope, replace: true) }
    @vault.update!(suspended_at: Time.current)
    @node.update!(content: "Later")
    begin
      Mnemodyne::Checkpoint.import(@vault, @envelope, replace: true)
    rescue Mnemodyne::Checkpoint::Invalid => error
      flunk("Synthetic restore failed: #{error.cause&.class}: #{error.cause&.message}")
    end
    assert_equal "Keep me", @vault.nodes.find(@node.id).content
    assert @vault.suspended_at?
  end

  test "failed restore rolls back all replacement rows" do
    @vault.update!(suspended_at: Time.current)
    @envelope["payload"]["nodes"].first["charge"] = 2
    @envelope["sha256"] = Digest::SHA256.hexdigest(JSON.generate(@envelope["payload"]))
    assert_raises(Mnemodyne::Checkpoint::Invalid) { Mnemodyne::Checkpoint.import(@vault, @envelope, replace: true) }
    assert_equal "Keep me", @node.reload.content
  end

  test "foreign identity tampering and implicit overwrite are rejected" do
    assert_raises(Mnemodyne::Checkpoint::Invalid) { Mnemodyne::Checkpoint.import(@vault, @envelope) }
    @envelope["payload"]["nodes"].first["content"] = "Tampered"
    assert_raises(Mnemodyne::Checkpoint::Invalid) { Mnemodyne::Checkpoint.import(@vault, @envelope) }
    foreign = agents(:code_reviewer).create_memory_vault!
    assert_raises(Mnemodyne::Checkpoint::Invalid) { Mnemodyne::Checkpoint.import(foreign, @envelope) }
    assert_empty foreign.nodes
  end

  test "malformed envelopes fail closed" do
    [ nil, [], {}, { "payload" => [], "sha256" => 0 } ].each do |envelope|
      assert_raises(Mnemodyne::Checkpoint::Invalid) { Mnemodyne::Checkpoint.import(@vault, envelope) }
    end
  end

end

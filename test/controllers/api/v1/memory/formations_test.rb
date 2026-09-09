require "test_helper"

class Api::V1::Memory::FormationsTest < ActionDispatch::IntegrationTest

  setup do
    @resident = agents(:research_assistant)
    @vault = @resident.create_memory_vault!
    @key = ApiKey.generate_for(users(:user_1), name: "Resident", agent: @resident)
    @headers = { "Authorization" => "Bearer #{@key.raw_token}", "Idempotency-Key" => "journal-shape" }
    @path = "/api/v1/memory/formations"
    @payload = {
      memory: { content: "My own handle", description: "My own reason", charge: 0.6,
        disclosure: "automatic", source_uris: [ "identity://memory/daily-journals/2026-09-09.md#22:00" ] },
      connections: [
        { target: { node_type: "person", content: "A real person" }, edge_type: "involves_person" },
        { target: { node_type: "need", content: "A recognised need" }, edge_type: "surfaced_need", weight: 0.7 }
      ]
    }
  end

  test "one request creates handle hubs and edges and identical retry reuses the receipt" do
    post @path, params: @payload, headers: @headers, as: :json
    assert_response :created
    receipt = response.parsed_body
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal 3, @vault.nodes.count
    assert_equal 2, @vault.edges.count
    assert_equal [ "never_automatic" ], @vault.nodes.where(node_type: %w[need person]).distinct.pluck(:disclosure)
    post @path, params: @payload, headers: @headers, as: :json
    assert_response :created
    assert_equal receipt, response.parsed_body
    assert_equal 3, @vault.nodes.count
    @payload[:memory][:content] = "Different"
    post @path, params: @payload, headers: @headers, as: :json
    assert_response :conflict
  end

  test "named hubs are reused without rewriting disclosure description or charge" do
    person = @vault.nodes.create!(node_type: "person", content: "A REAL PERSON",
      description: "Existing words", charge: 0.3, disclosure: "never_automatic")
    @payload[:connections][0][:target].merge!(description: "Do not replace", charge: 0.9, disclosure: "automatic")
    post @path, params: @payload, headers: @headers, as: :json
    assert_response :created
    assert_equal 3, @vault.nodes.count
    assert_equal "Existing words", person.reload.description
    assert_equal "never_automatic", person.disclosure
    assert_equal 0.3, person.charge
    assert_includes response.parsed_body["connections"].map { |c| c["target_id"] }, person.id
  end

  test "foreign targets and later invalid edges roll back all earlier writes" do
    foreign = agents(:code_reviewer).create_memory_vault!.nodes.create!(node_type: "need", content: "Private")
    @payload[:connections] << { target_id: foreign.id, edge_type: "theme" }
    assert_no_difference [ "Mnemodyne::Node.count", "Mnemodyne::Edge.count", "Mnemodyne::Operation.count" ] do
      post @path, params: @payload, headers: @headers, as: :json
      assert_response :not_found
    end
    @payload[:connections].last[:target_id] = foreign.id
    @payload[:connections][1][:weight] = 2
    assert_no_difference [ "Mnemodyne::Node.count", "Mnemodyne::Edge.count", "Mnemodyne::Operation.count" ] do
      post @path, params: @payload, headers: @headers, as: :json
      assert_response :unprocessable_entity
    end
  end

  test "empty links are honest but missing source typo fields and unbounded links are rejected" do
    @payload[:connections] = []
    post @path, params: @payload, headers: @headers, as: :json
    assert_response :created
    invalid = [
      @payload.deep_merge(memory: { source_uris: [] }),
      @payload.merge(connections: [ { from_node_id: "wrong", relation: "theme" } ]),
      @payload.merge(connections: [ {} ] * 21),
      @payload.merge(vault_id: @vault.id)
    ]
    invalid.each_with_index do |payload, index|
      assert_no_difference "Mnemodyne::Node.count" do
        post @path, params: payload, headers: @headers.merge("Idempotency-Key" => "invalid-#{index}"), as: :json
        assert_response :bad_request
      end
    end
  end

  test "suspended erasing and dormant state are never bypassed" do
    person = @vault.nodes.create!(node_type: "person", content: "A real person", is_dormant: true)
    post @path, params: @payload, headers: @headers, as: :json
    assert_response :conflict
    assert person.reload.is_dormant?
    @vault.update!(erasure_requested_at: Time.current)
    post @path, params: @payload, headers: @headers, as: :json
    assert_response :conflict
    @vault.update!(suspended_at: Time.current)
    post @path, params: @payload, headers: @headers, as: :json
    assert_response :forbidden
    assert_equal 1, @vault.nodes.count
  end

  test "forgetting a hub scrubs the formation receipt without resurrecting it on retry" do
    post @path, params: @payload, headers: @headers, as: :json
    person = @vault.nodes.find_by!(node_type: "person")
    delete "/api/v1/memory/nodes/#{person.id}", headers: @headers.merge("Idempotency-Key" => "forget")
    assert_response :success
    post @path, params: @payload, headers: @headers, as: :json
    assert_response :created
    assert_equal({ "forgotten" => true }, response.parsed_body)
    assert_nil @vault.nodes.find_by(id: person.id)
  end

end

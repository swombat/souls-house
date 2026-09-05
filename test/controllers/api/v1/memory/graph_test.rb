require "test_helper"

class Api::V1::Memory::GraphTest < ActionDispatch::IntegrationTest

  setup do
    @resident = agents(:research_assistant)
    @resident.update_columns(runtime: "external")
    @key = ApiKey.generate_for(users(:user_1), name: "Resident", agent: @resident)
    @headers = { "Authorization" => "Bearer #{@key.raw_token}", "Idempotency-Key" => "first" }
    @vault = @resident.create_memory_vault!
    @node = @vault.nodes.create!(node_type: "memory", content: "My private handle")
    peer = agents(:code_reviewer)
    peer.update_columns(runtime: "external")
    @foreign = peer.create_memory_vault!.nodes.create!(node_type: "memory", content: "Peer secret")
    @base = "/api/v1/memory"
  end

  test "requires resident credentials rather than account access" do
    get "#{@base}/nodes"
    assert_response :unauthorized
    human = ApiKey.generate_for(users(:user_1), name: "Human")
    get "#{@base}/nodes", headers: { "Authorization" => "Bearer #{human.raw_token}" }
    assert_response :forbidden
    @resident.update_columns(runtime: "inline")
    get "#{@base}/nodes", headers: @headers
    assert_response :forbidden
  end

  test "rejects disabled accounts inactive residents and suspended vaults" do
    @resident.account.update_columns(disabled_at: Time.current)
    get "#{@base}/nodes", headers: @headers
    assert_response :forbidden
    @resident.account.update_columns(disabled_at: nil)
    @resident.update_columns(active: false)
    get "#{@base}/nodes", headers: @headers
    assert_response :forbidden
    @resident.update_columns(active: true)
    @vault.update!(suspended_at: Time.current)
    get "#{@base}/nodes", headers: @headers
    assert_response :forbidden
  end

  test "lists only owned nodes ignoring supplied vault and resident IDs" do
    get "#{@base}/nodes", params: { vault_id: @foreign.vault_id, agent_id: @foreign.vault.agent_id }, headers: @headers
    assert_response :success
    assert_equal [ @node.id ], response.parsed_body["nodes"].map { |node| node["id"] }
    assert_not_includes response.body, "Peer secret"
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "foreign node show update delete and edge creation are inaccessible" do
    get "#{@base}/nodes/#{@foreign.id}", headers: @headers
    assert_response :not_found
    patch "#{@base}/nodes/#{@foreign.id}", params: { node: { content: "Overwrite" } }, headers: @headers, as: :json
    assert_response :not_found
    delete "#{@base}/nodes/#{@foreign.id}", headers: @headers
    assert_response :not_found
    post "#{@base}/edges", params: { edge: { source_id: @node.id, target_id: @foreign.id, edge_type: "theme" } }, headers: @headers, as: :json
    assert_response :not_found
    assert_equal "Peer secret", @foreign.reload.content
  end

  test "node creation and updates are idempotent and conflict on changed payload" do
    payload = { node: { node_type: "memory", content: "New", vault_id: @foreign.vault_id } }
    2.times do
      post "#{@base}/nodes", params: payload, headers: @headers, as: :json
      assert_response :created
    end
    assert_equal 2, @vault.nodes.count
    id = response.parsed_body.dig("node", "id")
    assert_equal @vault.id, Mnemodyne::Node.find(id).vault_id
    payload[:node][:content] = "Changed"
    post "#{@base}/nodes", params: payload, headers: @headers, as: :json
    assert_response :conflict
    2.times do
      patch "#{@base}/nodes/#{id}", params: { node: { is_dormant: true } }, headers: @headers.merge("Idempotency-Key" => "update"), as: :json
      assert_response :success
    end
    assert @vault.nodes.find(id).is_dormant?
  end

  test "edge CRUD supports retries and scopes every route" do
    target = @vault.nodes.create!(node_type: "need", content: "Care")
    2.times do
      post "#{@base}/edges", params: { edge: { source_id: @node.id, target_id: target.id, edge_type: "theme" } }, headers: @headers, as: :json
      assert_response :created
    end
    id = response.parsed_body.dig("edge", "id")
    assert_equal 1, @vault.edges.count
    get "#{@base}/edges/#{id}", headers: @headers
    assert_response :success
    patch "#{@base}/edges/#{id}", params: { edge: { weight: 0.8 } }, headers: @headers.merge("Idempotency-Key" => "edge-update"), as: :json
    assert_response :success
    assert_equal 0.8, @vault.edges.find(id).weight
    get "#{@base}/edges", params: { node_id: @foreign.id }, headers: @headers
    assert_response :not_found
    2.times do
      delete "#{@base}/edges/#{id}", headers: @headers.merge("Idempotency-Key" => "edge-delete")
      assert_response :success
    end
    assert_empty @vault.edges
  end

  test "validation errors and missing idempotency keys are bounded" do
    post "#{@base}/nodes", params: { node: { content: "Secret invalid value" } }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_not_includes response.body, "Secret invalid value"
    post "#{@base}/nodes", params: { node: { node_type: "memory", content: "New" } }, headers: @headers.except("Idempotency-Key"), as: :json
    assert_response :bad_request
    get "#{@base}/nodes", params: { limit: 101 }, headers: @headers
    assert_response :bad_request
  end

  test "constitutional nodes cannot be deleted" do
    @node.update!(integration_state: "constitutional")
    delete "#{@base}/nodes/#{@node.id}", headers: @headers
    assert_response :conflict
    assert @node.reload
  end

  test "memory request instrumentation filters private fields" do
    captured = []
    subscription = ActiveSupport::Notifications.subscribe("start_processing.action_controller") { |event| captured << event.payload[:params] }
    post "#{@base}/nodes", params: { node: { node_type: "memory", content: "Never log this handle" } }, headers: @headers, as: :json
    assert_response :created
    assert_not_empty captured
    assert_not_includes captured.to_json, "Never log this handle"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  test "SQL debug binds redact private graph attributes and operation responses" do
    buffer = StringIO.new
    logger = ActiveSupport::Logger.new(buffer)
    ActiveRecord::Base.stub(:logger, logger) do
      post "#{@base}/nodes", params: { node: { node_type: "memory", content: "Private SQL sentinel" } }, headers: @headers, as: :json
      assert_response :created
    end
    assert_includes buffer.string, "mnemodyne_nodes"
    assert_includes buffer.string, "[FILTERED]"
    assert_not_includes buffer.string, "Private SQL sentinel"
  end

  test "vault enablement is explicit idempotent and available while offline" do
    peer = agents(:other_account_agent)
    peer.update_columns(runtime: "offline")
    key = ApiKey.generate_for(users(:user_1), name: "Offline", agent: peer)
    headers = { "Authorization" => "Bearer #{key.raw_token}" }
    get "#{@base}/vault", headers: headers
    assert_response :success
    assert_not response.parsed_body["enabled"]
    2.times do
      post "#{@base}/vault", headers: headers
      assert_response :success
    end
    assert_equal 0, peer.reload.memory_vault.nodes.count
    assert_not peer.memory_vault.auto_preview_enabled?
  end

  test "resident can export schedule and cancel erasure while writes are frozen" do
    @resident.update_columns(uuid: SecureRandom.uuid)
    get "#{@base}/export", headers: @headers
    assert_response :success
    receipt = response.parsed_body.fetch("export_receipt")
    post "#{@base}/vault/erasure", headers: @headers, as: :json,
      params: { export_receipt: receipt, confirmation: @resident.uuid }
    assert_response :success
    assert response.parsed_body["erase_after"].present?
    patch "#{@base}/nodes/#{@node.id}", headers: @headers, as: :json, params: { node: { charge: 0.9 } }
    assert_response :conflict
    patch "#{@base}/vault", headers: @headers, as: :json, params: { auto_preview_enabled: true }
    assert_response :conflict
    get "#{@base}/export", headers: @headers
    assert_response :success
    delete "#{@base}/vault/erasure", headers: @headers
    assert_response :success
    assert_nil @vault.reload.erase_after
  end

  test "JSON recall receipts commit once and forgetting erases historical handles" do
    @node.update!(metadata: { baseline_activation: 1 })
    post "#{@base}/recalls", params: { seed_node_ids: [ @node.id ] }, headers: @headers, as: :json
    assert_response :success
    receipt = response.parsed_body.fetch("receipt")
    2.times do
      post "#{@base}/recalls/commit", params: { receipt: receipt, selected_node_ids: [ @node.id ], reason: "explicit_use" }, headers: @headers, as: :json
      assert_response :success
    end
    assert_equal 1, @vault.uses.count
    patch "#{@base}/nodes/#{@node.id}", params: { node: { description: "Private historical value" } }, headers: @headers, as: :json
    assert_response :success
    delete "#{@base}/nodes/#{@node.id}", headers: @headers.merge("Idempotency-Key" => "forget")
    assert_response :success
    assert_not_includes @vault.operations.pluck(:result).to_json, "Private historical value"
    assert_not_includes @vault.operations.pluck(:result).to_json, "My private handle"
  end

end

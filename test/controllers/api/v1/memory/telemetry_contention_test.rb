require "test_helper"

class Api::V1::Memory::TelemetryContentionTest < ActionDispatch::IntegrationTest

  self.use_transactional_tests = false

  class LockProbe < Mnemodyne::Record

    self.table_name = "mnemodyne_vaults"

  end

  test "actual contended telemetry never delays recall or masks its unavailable response" do
    agent = Agent.create!(account: accounts(:personal_account), name: "Synthetic telemetry",
      model_id: "openrouter/auto")
    agent.update_columns(runtime: "external")
    vault = agent.create_memory_vault!
    node = vault.nodes.create!(node_type: "memory", content: "Synthetic handle")
    key = ApiKey.generate_for(users(:user_1), name: "Synthetic telemetry", agent: agent)
    headers = { "Authorization" => "Bearer #{key.raw_token}" }
    LockProbe.establish_connection(ActiveRecord::Base.connection_db_config.configuration_hash)
    locked, release = Queue.new, Queue.new
    thread = Thread.new do
      LockProbe.connection_pool.with_connection do
        LockProbe.find(vault.id).with_lock do
          locked << true
          release.pop
        end
      end
    end
    locked.pop
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    post "/api/v1/memory/recalls", headers: headers, as: :json, params: { automatic: true }
    assert_response :success
    Mnemodyne::Embeddings.stub(:embed, ->(*) { raise Mnemodyne::Embeddings::Unavailable }) do
      post "/api/v1/memory/recalls", headers: headers, as: :json,
        params: { automatic: true, query: "Synthetic query" }
    end
    assert_response :service_unavailable
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
    assert_nil vault.reload.last_automatic_recall_at
  ensure
    release&.push(true)
    thread&.join(5)
    thread&.kill if thread&.alive?
    LockProbe.remove_connection
    key&.destroy!
    node&.destroy!
    vault&.destroy!
    agent&.reload&.destroy!
  end

end

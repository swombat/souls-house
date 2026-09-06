require "test_helper"

# Opt-in, actual local IO, always under bin/rails test's checkout lock. Ordinary
# tests neither start containers nor download models. Run via the documented
# scripts/verify-mnemodyne-local entrypoint after building the two local images.
if ENV["MNEMODYNE_LOCAL_SMOKE"] == "1"
  require "puma"
  require "net/http"

  class MnemodyneLocalSmokeTest < ActiveSupport::TestCase

    self.use_transactional_tests = false
    parallelize(workers: 1)

    test "real embeddings runtime CLI encrypted paired restore and erasure lifecycle" do
      assert LocalInstance.current.namespace
      assert_equal "test", LocalInstance.current.environment
      Agents::DockerLocalGuard.check!
      previous_env = ENV.to_h.slice("MNEMODYNE_LOCAL_BACKUP", "MNEMODYNE_LOCAL_BACKUP_AGENT_UUID", "MNEMODYNE_EMBEDDING_URL",
        "MNEMODYNE_EMBEDDING_PROFILE", "MNEMODYNE_EMBEDDING_TOKEN")
      ENV["MNEMODYNE_LOCAL_BACKUP"] = "1"
      @agent = Agent.create!(account: accounts(:personal_account), name: "Mnemodyne smoke #{SecureRandom.hex(6)}",
        model_id: "openrouter/auto", uuid: SecureRandom.uuid)
      ENV["MNEMODYNE_LOCAL_BACKUP_AGENT_UUID"] = @agent.uuid
      @agent.update_columns(runtime: "external")
      @resources = Agents::Resources.new(@agent)
      @agent.update!(container_name: @resources.container, container_image: ENV.fetch("MNEMODYNE_SMOKE_IMAGE", LocalInstance.current.image),
        restic_password: SecureRandom.hex(32), trigger_bearer_token: SecureRandom.hex(24))
      key = ApiKey.generate_for(users(:user_1), name: "Synthetic Mnemodyne smoke", agent: @agent)
      @agent.update!(outbound_api_key: key, outbound_api_token: key.raw_token)
      @resources.verify_existing!
      start_embeddings
      vectors = 3.times.map { Thread.new { Mnemodyne::Embeddings.embed("Synthetic simultaneous probe") } }.map(&:value)
      assert vectors.all? { |vector| vector.length == 384 }
      probe = Net::HTTP::Post.new(URI(ENV.fetch("MNEMODYNE_EMBEDDING_URL")), "Content-Type" => "application/json")
      probe.body = { input: "Synthetic authorization probe", model: ENV.fetch("MNEMODYNE_EMBEDDING_PROFILE") }.to_json
      uri = URI(ENV.fetch("MNEMODYNE_EMBEDDING_URL"))
      assert_equal "401", Net::HTTP.start(uri.host, uri.port) { |http| http.request(probe) }.code
      probe["Authorization"] = "Bearer #{ENV.fetch('MNEMODYNE_EMBEDDING_TOKEN')}"
      probe.body = { input: "Synthetic profile probe", model: "incorrect-profile" }.to_json
      assert_equal "400", Net::HTTP.start(uri.host, uri.port) { |http| http.request(probe) }.code
      @server = Puma::Server.new(Rails.application)
      @server.add_tcp_listener("0.0.0.0", 0)
      @server.run
      @port = @server.connected_ports.first
      @resources.volumes.each_value { |name| docker!("volume", "create", *@resources.labels, name) }
      start_runtime

      assert cli("status")["enabled"] == false
      docker!("exec", "--user", "1000", "-i", @resources.container, "python3",
        "/usr/local/share/helixkit-agent/memory_before_turn.py",
        input: { input_messages: [ { content: "Synthetic first hosted turn" } ] }.to_json)
      assert cli("status")["enabled"], "The lifecycle hook must provision without a manual enable command"
      dog = cli("--key", "dog", "remember", input: {
        node_type: "memory", content: "The dog played fetch with a tennis ball in the park.",
        source_uris: [ "identity://journal.md" ], disclosure: "automatic"
      }.to_json).fetch("node")
      bread = cli("--key", "bread", "remember", input: {
        node_type: "memory", content: "I baked sourdough bread in the kitchen.", disclosure: "automatic"
      }.to_json).fetch("node")
      need = cli("--key", "need", "remember", input: {
        node_type: "need", content: "Play", metadata: { baseline_activation: 0.8 }
      }.to_json).fetch("node")
      cli("--key", "connect", "connect", input: {
        source_id: dog["id"], target_id: need["id"], edge_type: "surfaced_need", weight: 0.9
      }.to_json)
      @vault = @agent.reload.memory_vault
      @vault.nodes.each { |node| Mnemodyne::EmbedNodeJob.perform_now(@vault.id, node.id) }
      @vault.nodes.reset
      assert_equal 384, @vault.nodes.find(dog["id"]).embedding.length
      before = @vault.nodes.order(:id).map(&:attributes)
      recall = cli("recall", "A puppy chasing a ball outside")
      scores = recall["results"].to_h { |node| [ node["id"], node["final_score"] ] }
      assert_operator scores.fetch(dog["id"]), :>, scores.fetch(bread["id"])
      assert_equal before, @vault.nodes.order(:id).map(&:attributes), "Preview mutated the graph"
      body = cli_raw("open", recall["recall_id"], dog["id"])
      assert_includes body, "Synthetic original identity source"
      assert_operator @vault.nodes.find(dog["id"]).reload.charge, :>, dog["charge"]
      cli("use", recall["recall_id"], dog["id"])
      assert_equal 1, @vault.uses.count
      notice = docker!("exec", "--user", "1000", "-i", @resources.container, "python3", "/home/agent/memory_client.py", "--preview",
        input: { enabled: true, query: "A puppy chasing a ball outside" }.to_json)
      assert_includes notice, "fallible memory"
      assert_includes notice, dog["id"]
      # Run the image's real shim subprocess boundary and both prompt forms,
      # but never invoke a paid model or a real resident.
      shim = <<~PY
        import sys
        sys.path.insert(0, "/home/agent")
        import trigger_shim as s
        n = s.graph_memory_notice({"enabled": True, "query": "A puppy chasing a ball outside"})
        assert "fallible memory" in n
        fresh, sizes = s.build_prompt_with_components("FRESH TRANSCRIPT", memory_notice=n)
        resumed = s.append_runtime_notice("CURRENT DELTA", n)
        assert "FRESH TRANSCRIPT" in fresh and "fallible memory" in fresh
        assert "CURRENT DELTA" in resumed and "fallible memory" in resumed
        assert sizes["graph_memory"] > 0
        print("Fresh and resumed image paths passed")
      PY
      assert_includes docker!("exec", "--user", "1000", @resources.container, "python3", "-c", shim), "image paths passed"

      # A malformed resident-authored hooks file must survive recovery without
      # bricking the real entrypoint or silently losing the original bytes.
      docker!("exec", @resources.container, "python3", "-c",
        "from pathlib import Path; p=Path('/home/agent/repo/.chaos/hooks.json'); p.parent.mkdir(parents=True, exist_ok=True); p.write_text('{ synthetic invalid hooks')")
      snapshot = Backup::AgentResticJob.perform_now(@agent.id, force: true)
      assert snapshot.ok?
      assert snapshot.graph_checkpoint_digest.present?
      old_token = @agent.outbound_api_token
      docker!("exec", @resources.container, "python3", "-c",
        "from pathlib import Path; Path('/home/agent/identity/journal.md').write_text('Changed after backup')")
      @vault.nodes.find(dog["id"]).update!(content: "Changed after backup")
      # Real spawn/entrypoint/health path, with no provider keys or model call.
      @agent.account.update!(use_system_ai_credentials: false,
        **Account::AI_PROVIDERS.keys.to_h { |provider| [ "#{provider}_api_key", nil ] })
      assert_empty @agent.account.ai_provider_keys
      Agents::Config.stub(:internal_url, "http://host.docker.internal:#{@port}") do
        Agents::Config.stub(:default_image, @agent.container_image) do
          result = Backup::AgentResticRestore.new(@agent).restore!(wake: true)
          assert result[:awake]
        end
      end
      assert_nil ApiKey.authenticate(old_token)
      assert_not_equal old_token, @agent.reload.outbound_api_token
      assert_equal dog["content"], @vault.nodes.find(dog["id"]).content
      assert_not @vault.reload.suspended_at?
      assert_includes docker!("exec", @resources.container, "cat", "/home/agent/identity/journal.md"), "Synthetic original"
      assert_equal @agent.outbound_api_token,
        docker!("exec", @resources.container, "printenv", "SOULSHOUSE_BEARER_TOKEN").strip
      assert cli("status")["enabled"]
      hooks = JSON.parse(docker!("exec", @resources.container, "cat", "/home/agent/repo/.chaos/hooks.json"))
      assert_equal 1, hooks.fetch("hooks").fetch("BeforeTurn").length
      assert_equal 1, hooks.fetch("hooks").fetch("Stop").length
      preserved = docker!("exec", @resources.container, "python3", "-c",
        "from pathlib import Path; p=list(Path('/home/agent/repo/.chaos').glob('hooks.json.invalid-*')); assert len(p)==1; assert p[0].stat().st_mode & 0o777 == 0o600; print(p[0].read_text())")
      assert_equal "{ synthetic invalid hooks", preserved.strip
      @vault.nodes.reset
      @vault.nodes.each { |node| Mnemodyne::EmbedNodeJob.perform_now(@vault.id, node.id) }
      before_turn = docker!("exec", "--user", "1000", "-i", @resources.container, "python3",
        "/home/agent/identity/automation/memory_before_turn.py",
        input: { input_messages: [ { content: "A puppy chasing a ball outside" } ] }.to_json)
      assert_includes JSON.parse(before_turn).dig("hookSpecificOutput", "additionalContext"), "fallible memory"
      assert_includes cli_raw("guide"), "Your memory, with handles"
      stop = <<~PY
        import json, subprocess
        result = subprocess.run(["python3", "/home/agent/identity/automation/stop_journal_reflex.py"],
            input=json.dumps({"last_assistant_message": "Synthetic completed turn"}), capture_output=True, text=True)
        assert result.returncode == 2
        assert "house-memory remember" in result.stderr and "house-memory connect" in result.stderr
        assert "no shape" in result.stderr
        print("Automatic formation reflex present")
      PY
      assert_includes docker!("exec", "--user", "1000", @resources.container, "python3", "-c", stop), "Automatic formation reflex present"

      cli_raw("export", "--output", "/home/agent/work/export.json")
      exported_mode = docker!("exec", @resources.container, "stat", "-c", "%a", "/home/agent/work/export.json")
      assert_equal "600", exported_mode.strip
      scheduled = cli("request-erasure", "--export", "/home/agent/work/export.json", "--confirm", @agent.uuid)
      assert scheduled["erase_after"].present?
      cli("cancel-erasure")
      assert_nil @vault.reload.erase_after
      cli("request-erasure", "--export", "/home/agent/work/export.json", "--confirm", @agent.uuid)
      travel 8.days do
        Mnemodyne::EraseVaultsJob.perform_now
        assert_not cli("status")["enabled"]
        error = assert_raises(Backup::AgentResticRestore::RestoreError) do
          Backup::AgentResticRestore.new(@agent.reload).restore!(wake: false)
        end
        assert_includes error.message, "predates deliberate memory erasure"
      end
      puts "PASS: real CPU inference, HTTP API/image CLI, nonmutating recall, commit-on-open, runtime preview, encrypted paired restore, rotated credentials and erasure"
    ensure
      @server&.stop(true)
      cleanup_owned_resources
      previous_env&.each { |key, value| ENV[key] = value }
      %w[MNEMODYNE_LOCAL_BACKUP MNEMODYNE_LOCAL_BACKUP_AGENT_UUID MNEMODYNE_EMBEDDING_URL MNEMODYNE_EMBEDDING_PROFILE MNEMODYNE_EMBEDDING_TOKEN].each do |key|
        ENV.delete(key) unless previous_env&.key?(key)
      end
    end

    private

    def docker!(*command, input: "")
      out, error, status = Open3.capture3("docker", *command, stdin_data: input)
      raise "Synthetic Docker operation failed (#{command.first}): #{error.last(2000)}" unless status.success?
      out
    end

    def start_embeddings
      @embedding_container = "#{@resources.container}-embeddings"
      ENV["MNEMODYNE_EMBEDDING_TOKEN"] = SecureRandom.hex(32)
      docker!("run", "--pull", "never", "-d", "--name", @embedding_container, *@resources.labels,
        "--read-only", "--tmpfs", "/tmp", "--cpus", "2", "--memory", "512m",
        "-p", "127.0.0.1::8080", "-e", "MNEMODYNE_EMBEDDING_TOKEN=#{ENV['MNEMODYNE_EMBEDDING_TOKEN']}",
        "souls-house-mnemodyne-embeddings:local-#{LocalInstance.current.number}")
      port = docker!("port", @embedding_container, "8080").strip.split(":").last
      base = "http://127.0.0.1:#{port}"
      30.times do
        begin
          response = Net::HTTP.get_response(URI("#{base}/health"))
          if response.code == "200"
            ENV["MNEMODYNE_EMBEDDING_URL"] = "#{base}/v1/embeddings"
            ENV["MNEMODYNE_EMBEDDING_PROFILE"] = JSON.parse(response.body).fetch("profile")
            return
          end
        rescue SystemCallError, EOFError
        end
        sleep 1
      end
      flunk "Owned embedding service did not become ready"
    end

    def start_runtime(write_source: true)
      mounts = @resources.volumes.flat_map { |kind, name| [ "-v", "#{name}:#{{
        identity: "/home/agent/identity", chaos: "/home/agent/.chaos", repo: "/home/agent/repo",
        work: "/home/agent/work", state: "/home/agent/state" }.fetch(kind)}" ] }
      docker!("run", "--pull", "never", "-d", "--name", @resources.container, *@resources.labels, *mounts,
        "--user", "0", "-e", "SOULSHOUSE_APP_URL=http://host.docker.internal:#{@port}",
        "-e", "SOULSHOUSE_BEARER_TOKEN=#{@agent.outbound_api_token}",
        "-e", "TRIGGER_BEARER_TOKEN=#{@agent.trigger_bearer_token}",
        "--entrypoint", "python3", ENV.fetch("MNEMODYNE_SMOKE_IMAGE", @agent.container_image),
        "-c", "import time; time.sleep(3600)")
      if write_source
        docker!("exec", @resources.container, "python3", "-c",
          "from pathlib import Path; Path('/home/agent/identity/journal.md').write_text('Synthetic original identity source')")
      end
      docker!("exec", @resources.container, "chown", "-R", "1000:1000",
        "/home/agent/identity", "/home/agent/state", "/home/agent/work")
    end

    def cli_raw(*arguments, input: "")
      docker!("exec", "--user", "1000", "-i", @resources.container, "house-memory", *arguments, input: input)
    end

    def cli(*arguments, input: "")
      JSON.parse(cli_raw(*arguments, input: input))
    end

    def cleanup_owned_resources
      return unless @resources
      @resources.verify_existing!
      [ @embedding_container, @resources.container ].compact.each do |name|
        # Names belong to this run, and labels are checked before deletion.
        out, _, status = Open3.capture3("docker", "inspect", "--format",
          '{{ index .Config.Labels "house.souls.checkout" }}', name)
        next unless status.success?
        raise "Foreign synthetic container" unless out.strip == LocalInstance.current.fingerprint
        docker!("rm", "-f", name)
      end
      (@resources.volumes.values + [ "#{@resources.container}-backups" ]).each do |name|
        out, _, status = Open3.capture3("docker", "volume", "inspect", "--format",
          '{{ index .Labels "house.souls.checkout" }}', name)
        next unless status.success?
        raise "Foreign synthetic volume" unless out.strip == LocalInstance.current.fingerprint
        docker!("volume", "rm", name)
      end
      vault = @agent.reload.memory_vault
      if vault
        [ Mnemodyne::Use, Mnemodyne::Operation, Mnemodyne::Edge, Mnemodyne::Node ].each { |model| model.where(vault_id: vault.id).delete_all }
        vault.destroy!
      end
      @agent.update!(outbound_api_key: nil)
      ApiKey.where(agent_id: @agent.id).find_each(&:destroy!)
      @agent.reload.destroy!
    end

  end
end

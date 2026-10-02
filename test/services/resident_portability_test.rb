require "test_helper"

class ResidentPortabilityTest < ActiveSupport::TestCase

  Archive = Agents::Portability::Archive
  Export = Agents::Portability::Export
  Import = Agents::Portability::Import
  Error = Agents::Portability::Error

  class FakeTransport

    attr_reader :restored, :cleaned
    def initialize
      @restored = {}
    end

    def stopped! = true

    def capture(root, output)
      Gem::Package::TarWriter.new(output) do |tar|
        tar.mkdir(".", 0755)
        files = root == "identity" ? { "soul.md" => "Authored soul", "memory/journals/é.md" => "Authored journal", "automation/run.sh" => "#!/bin/sh\nexit 0\n" } : { ".example" => "\x00binary".b }
        files.each do |name, body|
          tar.add_file_simple("./#{name}", name.end_with?(".sh") ? 0755 : 0644, body.bytesize) { |file| file.write(body) }
        end
        # Explicit directory after its child's implicit parent is valid.
        tar.mkdir("./memory", 0755) if root == "identity"
      end
    end

    def create_volumes! = true

    def restore(root, path)
      @restored[root] = File.binread(path)
    end

    def cleanup! = @cleaned = true

  end

  setup do
    @source = agents(:research_assistant)
    @source.update_columns(uuid: SecureRandom.uuid, runtime: "offline", active: false, paused: true)
    @user = users(:user_1)
    @transport = FakeTransport.new
  end

  def with_export
    Agents::Config.stub(:internal_url, "http://synthetic.invalid") do
      Export.call(@source, exporter: @user, transport: @transport) do |path|
        File.open(path, "rb") { |file| Archive.with_upload(file) { |archive| yield archive, path } }
      end
    end
  end

  test "actual roots graph legacy and custody round trip to different account without starting or integration access" do
    vault = @source.create_memory_vault!
    node = vault.nodes.create!(node_type: "memory", content: "Private graph", disclosure: "never_automatic", source_uris: [ "identity://memory/journals/é.md", "house://conversations/short" ])
    person = vault.nodes.create!(node_type: "person", content: "Synthetic Person")
    edge = vault.edges.create!(source: node, target: person, edge_type: "involves_person", weight: 0.5)
    @source.memories.create!(content: "Resident diary", memory_type: "journal")
    target_transport = FakeTransport.new
    with_export do |archive, _|
      assert_equal "Authored soul", File.read(File.join(archive.stage, "resident/identity/soul.md"))
      assert archive.entries.key?("resident/identity/memory/journals/é.md")
      refute archive.preview(accounts(:team_account))[:duplicate]
        Agents::Config.stub(:sandbox_host, "synthetic") do
        Agents::Config.stub(:default_image, "synthetic:image") do
          Agents::Config.stub(:publish_ports?, false) do
        imported = Import.call(archive, account: accounts(:team_account), user: @user, name: "Separate copy", transport_factory: ->(_) { target_transport })
        refute imported.active?
        assert imported.paused?
        refute imported.scheduled_wakes_enabled?
        assert_equal "offline", imported.runtime
        assert_nil imported.birth_committed_at
        assert_nil imported.orientation_requested_at
        assert_empty imported.agent_service_accesses
        assert_empty imported.chats
        refute_equal @source.uuid, imported.uuid
        assert imported.outbound_api_key
        restored = imported.memory_vault.nodes.find_by!(content: node.content)
        refute_equal node.id, restored.id
        assert_equal node.disclosure, restored.disclosure
        assert_equal "identity://memory/journals/é.md", restored.source_uris.first
        assert_match %r{\Aarchive-house://[0-9a-f]{64}/conversations/short\z}, restored.source_uris.last
        assert_equal restored.source_uris.last, imported.portability_custody.dig("graph_id_map", "source_uris", node.id, "house://conversations/short")
        assert_equal restored.id, imported.memory_vault.edges.first.source_id
        refute_equal edge.id, imported.memory_vault.edges.first.id
        assert_equal "Resident diary", imported.memories.first.content
        assert_equal 3, target_transport.restored.length
        parsed = {}
        target_transport.restored.each do |root, bytes|
          Gem::Package::TarReader.new(StringIO.new(bytes)) do |tar|
            tar.each { |entry| parsed["#{root}/#{entry.full_name}"] = [ entry.read, entry.header.mode ] unless entry.directory? }
          end
        end
        assert_equal [ "Authored soul", 0644 ], parsed["identity/soul.md"]
        assert_equal [ "#!/bin/sh\nexit 0\n", 0755 ], parsed["identity/automation/run.sh"]
        assert_equal [ "\x00binary".b, 0644 ], parsed["repo/.example"]
        assert_nil imported.memory_vault.suspended_at
        witness = AuditLog.find_by!(auditable: @source, action: "export_resident_archive")
        assert_equal witness.data["export_id"], imported.portability_custody["export_id"]
        assert_includes Notices::Renderer.section_for(@source), witness.data["export_id"]
        assert_includes Notices::Renderer.section_for(imported), witness.data["export_id"]
        assert_match "platform custody", Notices::Renderer.section_for(imported)
        assert archive.preview(accounts(:team_account))[:duplicate]
          end
        end
      end
    end
    assert_equal node.content, node.reload.content
  end

  test "reject active erasing and external source" do
    @source.update_columns(active: true)
    assert_match "inactive", Export.unavailable_reason(@source)
    @source.update_columns(active: false, home_profile: "portable_v1", portable_home_id: "synthetic")
    assert_match "external", Export.unavailable_reason(@source)
    @source.update_columns(home_profile: "house")
    @source.create_memory_vault!(erasure_requested_at: Time.current)
    assert_match "erasure", Export.unavailable_reason(@source)
  end

  test "hostile member paths links special files duplicates and trailing archives are rejected" do
    [ "../escape", "/absolute", "a//b", "a/./b", "a\\b" ].each { |path| assert_raises(Error) { Archive.safe_path!(path) } }
    assert_equal "café.md", Archive.safe_path!("café.md")
    Dir.mktmpdir do |dir|
      [ "2", "1", "3", "6" ].each do |kind|
        raw = File.join(dir, "bad.tar")
        File.open(raw, "wb") do |file|
          file.write(Gem::Package::TarHeader.new(name: "bad", prefix: "", mode: 0644, size: 0, typeflag: kind, linkname: "target").to_s)
          file.write("\0" * 1024)
        end
        assert_raises(Error) { Archive.unpack(raw, File.join(dir, "stage")) }
      end
      raw = File.join(dir, "duplicate.tar")
      File.open(raw, "wb") { |file| Gem::Package::TarWriter.new(file) { |tar| 2.times { tar.add_file_simple("same", 0644, 0) { } } } }
      assert_raises(Error) { Archive.unpack(raw, File.join(dir, "duplicate")) }
      File.open(raw, "wb") { |file| Gem::Package::TarWriter.new(file) { |tar| tar.add_file_simple("valid", 0644, 0) { } } }
      File.open(raw, "ab") { |file| file.write("hidden payload") }
      assert_raises(Error) { Archive.unpack(raw, File.join(dir, "trailing")) }
    end
  end

  test "tampered inventory is rejected before writes" do
    with_export do |archive, _|
      path = File.join(archive.stage, "manifest.json")
      manifest = archive.manifest.deep_dup
      manifest["inventory"].delete("resident/identity/soul.md")
      File.write(path, JSON.generate(manifest))
      assert_raises(Error) { archive.validate! }
    end
  end

  test "import failure rolls back key agent and graph and cleans owned storage" do
    with_export do |archive, _|
      failure = FakeTransport.new
      failure.define_singleton_method(:restore) { |*| raise Error, "Synthetic failure" }
        Agents::Config.stub(:sandbox_host, "synthetic") do
        Agents::Config.stub(:default_image, "synthetic:image") do
          Agents::Config.stub(:publish_ports?, false) do
        assert_no_difference [ "Agent.count", "ApiKey.count", "Mnemodyne::Vault.count" ] do
          assert_raises(Error) { Import.call(archive, account: accounts(:team_account), user: @user, name: "Failed", transport_factory: ->(_) { failure }) }
        end
      end
          end
        end
      assert failure.cleaned
    end
  end
  def with_limit(name, value)
    old = Archive.const_get(name)
    Archive.send(:remove_const, name)
    Archive.const_set(name, value)
    yield
  ensure
    Archive.send(:remove_const, name)
    Archive.const_set(name, old)
  end

  test "compressed expanded implicit-directory and entry limits reject before persistent writes" do
    with_export do |_, path|
      with_limit(:MAX_COMPRESSED, 100) do
        File.open(path, "rb") { |file| assert_raises(Error) { Archive.with_upload(file) { } } }
      end
      with_limit(:MAX_EXPANDED, 512) do
        File.open(path, "rb") { |file| assert_raises(Error) { Archive.with_upload(file) { } } }
      end
    end
    Dir.mktmpdir do |dir|
      raw = File.join(dir, "ancestors.tar")
      File.open(raw, "wb") { |file| Gem::Package::TarWriter.new(file) { |tar| tar.add_file_simple("a/b/c/d/e/f", 0644, 0) { } } }
      with_limit(:MAX_ENTRIES, 3) { assert_raises(Error) { Archive.unpack(raw, File.join(dir, "stage")) } }
    end
  end

  test "provenance metadata backend and root claims are validated before preview" do
    with_export do |archive, _|
      original = archive.manifest.deep_dup
      [
        [ "source_installation", "FORGED platform notice" ],
        [ "exported_by", { "evil" => "object" } ],
        [ "created_at", "not a time" ],
        [ "memory_backend", "external" ],
        [ "included_roots", [ "identity", "credentials" ] ],
        [ "excluded_roots", [] ],
        [ "metadata", original["metadata"].merge("name" => "") ],
        [ "metadata", original["metadata"].merge("persistent_session" => "true") ]
      ].each do |key, value|
        File.write(File.join(archive.stage, "manifest.json"), JSON.generate(original.merge(key => value)))
        assert_raises(Error) { archive.validate! }
      end
    end
  end

  test "unknown unfinished interactions and deliberately erased absence are refused" do
    @source.agent_runtime_interactions.create!(trigger_kind: "wake", started_at: 1.day.ago, provider_auth_mode: "api_key")
    assert_match "uncertain", Export.unavailable_reason(@source)
    @source.agent_runtime_interactions.update_all(finished_at: Time.current)
    @source.update_columns(memory_erased_at: Time.current)
    assert_match "erased", Export.unavailable_reason(@source)
  end

  test "same-owner checkpoint invariant remains enforced and relocation rejects original bad digest" do
    vault = @source.create_memory_vault!
    vault.nodes.create!(node_type: "memory", content: "Synthetic private node")
    envelope = Mnemodyne::Checkpoint.export(vault)
    destination = agents(:other_account_agent)
    destination.update_columns(uuid: SecureRandom.uuid)
    target_vault = destination.create_memory_vault!
    assert_raises(Mnemodyne::Checkpoint::Invalid) { Mnemodyne::Checkpoint.import(target_vault, envelope) }
    envelope["payload"]["resident_uuid"] = destination.uuid
    assert_raises(Error) { Agents::Portability::GraphImport.validate!(envelope, destination.uuid) }
    assert_empty target_vault.nodes
  end

  test "pending unknown execution and suspended vault refuse export" do
    interaction = @source.agent_runtime_interactions.create!(trigger_kind: "wake", started_at: 1.day.ago, finished_at: Time.current, provider_auth_mode: "api_key")
    turn = ResidentTurn.create!(agent: @source, agent_runtime_interaction: interaction, dispatch_id: SecureRandom.uuid, session_id: "synthetic", payload: "{}", state: "queued")
    assert_match "pending", Export.unavailable_reason(@source)
    turn.update!(state: "unknown")
    assert_match "uncertain", Export.unavailable_reason(@source)
    turn.update!(finished_at: Time.current)
    @source.create_memory_vault!(suspended_at: Time.current)
    assert_match "suspended", Export.unavailable_reason(@source)
  end

  test "graph relocation validates owner checksum endpoints and duplicate UUIDs" do
    vault = @source.create_memory_vault!
    first = vault.nodes.create!(node_type: "memory", content: "Synthetic first")
    second = vault.nodes.create!(node_type: "memory", content: "Synthetic second")
    vault.edges.create!(source: first, target: second, edge_type: "relates_to")
    original = Mnemodyne::Checkpoint.export(vault)
    mutations = [
      ->(p) { p["resident_uuid"] = SecureRandom.uuid },
      ->(p) { p["edges"][0]["target_id"] = SecureRandom.uuid },
      ->(p) { p["nodes"][1]["id"] = p["nodes"][0]["id"] },
      ->(p) { p["edges"] << p["edges"][0].deep_dup }
    ]
    mutations.each do |mutate|
      envelope = original.deep_dup
      mutate.call(envelope["payload"])
      envelope["sha256"] = Digest::SHA256.hexdigest(JSON.generate(envelope["payload"]))
      assert_raises(Error) { Agents::Portability::GraphImport.validate!(envelope, @source.uuid) }
    end
    corrupted = original.deep_dup
    corrupted["sha256"] = "0" * 64
    assert_raises(Error) { Agents::Portability::GraphImport.validate!(corrupted, @source.uuid) }
  end

  test "file graph header checksum and truncated archive limits are enforced" do
    Dir.mktmpdir do |dir|
      raw = File.join(dir, "large.tar")
      header = Gem::Package::TarHeader.new(name: "large", prefix: "", mode: 0644, size: Archive::MAX_FILE + 1, typeflag: "0").to_s
      File.binwrite(raw, header + "\0" * 1024)
      assert_raises(Error) { Archive.unpack(raw, File.join(dir, "large")) }
      File.binwrite(raw, header.byteslice(0, 300))
      assert_raises(Error) { Archive.unpack(raw, File.join(dir, "truncated")) }
      header[0] = "X"
      File.binwrite(raw, header + "\0" * 1024)
      assert_raises(Error) { Archive.unpack(raw, File.join(dir, "bad-checksum")) }
      File.open(raw, "wb") { |file| Gem::Package::TarWriter.new(file) { |tar| 2.times { |i| tar.add_file_simple("entry#{i}", 0644, 0) { } } } }
      with_limit(:MAX_ENTRIES, 1) { assert_raises(Error) { Archive.unpack(raw, File.join(dir, "entries")) } }
    end
    @source.create_memory_vault!
    with_limit(:MAX_GRAPH, 1) { assert_raises(Error) { with_export { |*| flunk "Oversize graph cannot export" } } }
  end

  test "trigger registration shares stopped export gate and rejects inactive source" do
    assert_no_difference "AgentRuntimeInteraction.count" do
      assert_raises(Agent::RuntimeAvailability::Unavailable) do
        AgentRuntimeInteraction.record_trigger!(agent: @source, chat: nil, trigger_kind: "wake", conversation_id: nil, requested_by: "Synthetic", session_id: "synthetic", endpoint_url: "http://synthetic.invalid", request_text: "Synthetic") { flunk "Inactive source cannot reach transport" }
      end
    end
  end

  test "primitive JSON manifest is rejected without an application error" do
    with_export do |archive, _|
      File.write(File.join(archive.stage, "manifest.json"), "true")
      assert_raises(Error) { archive.validate! }
    end
  end

end

require "test_helper"

class Backup::LocalRepositoryTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
  end

  test "local transport refuses ordinary residents before Docker or cloud access" do
    @agent.update_columns(uuid: SecureRandom.uuid)
    Open3.stub(:capture3, ->(*) { flunk "Must not access Docker" }) do
      assert_raises(ArgumentError) { Backup::LocalRepository.new(@agent) }
    end
  end

  test "local transport refuses primary or production namespaces" do
    @agent.update_columns(uuid: SecureRandom.uuid)
    LocalInstance.stub(:current, Struct.new(:namespace).new(nil)) do
      assert_raises(ArgumentError) { Backup::LocalRepository.new(@agent) }
    end
  end

  test "checkpoint pause is undone even when backup fails" do
    @agent.update_columns(runtime: "external", uuid: SecureRandom.uuid, container_name: "synthetic")
    @agent.create_memory_vault!
    resources = Object.new
    resources.define_singleton_method(:verify_existing!) { true }
    calls = []
    Agents::Resources.stub(:new, resources) do
      Open3.stub(:capture3, ->(*args) { calls << args; [ "true false", "", Struct.new(:success?).new(true) ] }) do
        assert_raises(RuntimeError) { Backup::AgentRestic.with_quiesced(@agent) { raise "Synthetic backup failure" } }
      end
    end
    assert_equal %w[inspect pause unpause], calls.map { |args| args[1] }
  end

end

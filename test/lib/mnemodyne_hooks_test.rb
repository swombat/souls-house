require "test_helper"
require "open3"
require "tmpdir"

class MnemodyneHooksTest < ActiveSupport::TestCase

  test "managed hooks merge idempotently without removing resident hooks" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "hooks.json")
      File.write(path, { hooks: { Stop: [ { hooks: [ { type: "command", command: "my-private-hook" } ] } ] } }.to_json)
      2.times do
        _, error, result = Open3.capture3("python3", Rails.root.join("agent-runtime/install_memory_hooks.py").to_s, path)
        assert result.success?, error
      end
      hooks = JSON.parse(File.read(path)).fetch("hooks")
      assert_equal 2, hooks.fetch("Stop").length
      assert_equal 1, hooks.fetch("BeforeTurn").length
      assert_includes File.read(path), "my-private-hook"
    end
  end

  test "stop reflex automatically invites journal then source linked formation only once" do
    Dir.mktmpdir do |dir|
      env = { "AGENT_IDENTITY_PATH" => dir }
      script = Rails.root.join("agent-runtime/stop_journal_reflex.py").to_s
      event = { last_assistant_message: "Synthetic meaningful turn" }
      _, prompt, result = Open3.capture3(env, "python3", script, stdin_data: event.to_json)
      assert_equal 2, result.exitstatus
      assert_includes prompt, "house-memory remember"
      assert_includes prompt, "house-memory connect"
      assert_includes prompt, "no shape"
      assert_includes prompt, "identity://memory/daily-journals/"
      _, prompt, result = Open3.capture3(env, "python3", script, stdin_data: event.merge(stop_hook_active: true).to_json)
      assert result.success?
      assert_empty prompt
      assert_empty Dir.glob("#{dir}/memory/daily-journals/*.md"), "The hook must not manufacture a journal"
    end
  end

end

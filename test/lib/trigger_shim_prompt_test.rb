require "test_helper"
require "tmpdir"

class TriggerShimPromptTest < ActiveSupport::TestCase

  test "prompt places soul first and reads back recent journals" do
    Dir.mktmpdir do |dir|
      identity = Pathname.new(dir)
      (identity / "memory" / "daily-journals").mkpath
      (identity / "soul.md").write("SOUL FIRST\n")
      (identity / "runtime-instructions.md").write("STALE IDENTITY RUNTIME CONTEXT\n")
      (identity / "self-narrative.md").write("Self narrative\n")
      (identity / "bootstrap.md").write("Bootstrap\n")
      (identity / "memory" / "daily-journals" / "2026-05-28.md").write("# Daily Journal: 2026-05-28\n\n## 10:00 — Live edge\n\nToday I woke here.\n")
      (identity / "memory" / "daily-journals" / "2026-05-27.md").write("# Daily Journal: 2026-05-27\n\n## 09:00 — Previous title\n\nOlder body should not load.\n")

      prompt = build_prompt_with_python(identity)

      assert prompt.start_with?("SOUL FIRST\n"), "soul.md should be first in the prompt"
      assert_includes prompt, "## Hosted runtime instructions: #{Rails.root.join('agent-runtime/docs/runtime-instructions.md')}"
      assert_includes prompt, "authoritative API and helper reference"
      assert_includes prompt, "a historical export"
      assert_includes prompt, "identity/runtime-instructions.md.new"
      assert_not_includes prompt, "STALE IDENTITY RUNTIME CONTEXT"
      assert_includes prompt, 'helixkit-post-message "$CHAT_ID" --attach /tmp/image.png'
      assert_includes prompt, "soulshouse-usage"
      assert_includes prompt, "/tmp/<image_id>.png"
      assert_includes prompt, "not recency-limited"
      assert_includes prompt, "next_cursor"
      assert_operator prompt.index("REQUEST"), :<, prompt.index("## Memory context — not current chat transcript")
      assert_includes prompt, "They are not current HelixKit chat messages, not trigger payload, and not the live transcript"
      assert_includes prompt, "## Your recent journal entries"
      assert_includes prompt, "Today I woke here."
      assert_includes prompt, "## 09:00 — Previous title"
      assert_not_includes prompt, "Older body should not load."
    end
  end

  test "fresh prompt places dynamic runtime notice after the request and before memory" do
    Dir.mktmpdir do |dir|
      identity = Pathname.new(dir)
      (identity / "memory" / "daily-journals").mkpath
      (identity / "soul.md").write("SOUL FIRST\n")
      (identity / "memory" / "daily-journals" / "2026-08-31.md").write("# Daily Journal\n\n## 08:00 — Earlier\n")

      script = Rails.root.join("agent-runtime/trigger_shim.py")
      command = <<~PY
        import importlib.util
        spec = importlib.util.spec_from_file_location("trigger_shim", #{script.to_s.inspect})
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        print(mod.build_prompt_with_components("REQUEST", runtime_notice="USAGE NOTICE")[0])
      PY
      env = {
        "TRIGGER_BEARER_TOKEN" => "tr_test",
        "AGENT_IDENTITY_PATH" => identity.to_s,
        "AGENT_RUNTIME_DOCS_PATH" => Rails.root.join("agent-runtime/docs").to_s
      }
      prompt, stderr, status = Open3.capture3(env, "python3", "-c", command)

      assert status.success?, stderr
      assert_operator prompt.index("REQUEST"), :<, prompt.index("USAGE NOTICE")
      assert_operator prompt.index("USAGE NOTICE"), :<, prompt.index("## Memory context")
    end
  end

  test "prompt omits journal section when no daily journals exist" do
    Dir.mktmpdir do |dir|
      identity = Pathname.new(dir)
      (identity / "memory" / "daily-journals").mkpath
      (identity / "soul.md").write("SOUL FIRST\n")

      prompt = build_prompt_with_python(identity)

      assert_not_includes prompt, "## Your recent journal entries"
    end
  end

  test "prompt tails a large most recent journal" do
    Dir.mktmpdir do |dir|
      identity = Pathname.new(dir)
      (identity / "memory" / "daily-journals").mkpath
      (identity / "soul.md").write("SOUL FIRST\n")
      large = "# Daily Journal: 2026-05-28\n\n" + ("old\n" * 4_000) + "TAIL-MARKER\n"
      (identity / "memory" / "daily-journals" / "2026-05-28.md").write(large)

      prompt = build_prompt_with_python(identity)

      assert_includes prompt, "# Daily Journal: 2026-05-28"
      assert_includes prompt, "TAIL-MARKER"
      assert_includes prompt, "older content truncated"
      assert_operator prompt.length, :<, large.length
    end
  end

  private

  def build_prompt_with_python(identity)
    script = Rails.root.join("agent-runtime/trigger_shim.py")
    command = <<~PY
      import importlib.util
      spec = importlib.util.spec_from_file_location("trigger_shim", #{script.to_s.inspect})
      mod = importlib.util.module_from_spec(spec)
      spec.loader.exec_module(mod)
      print(mod.build_prompt("REQUEST"))
    PY
    env = {
      "TRIGGER_BEARER_TOKEN" => "tr_test",
      "AGENT_IDENTITY_PATH" => identity.to_s,
      "AGENT_RUNTIME_DOCS_PATH" => Rails.root.join("agent-runtime/docs").to_s
    }
    stdout, stderr, status = Open3.capture3(env, "python3", "-c", command)
    assert status.success?, stderr
    stdout
  end

end

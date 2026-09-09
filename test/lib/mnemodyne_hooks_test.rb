require "test_helper"
require "open3"
require "tmpdir"

class MnemodyneHooksTest < ActiveSupport::TestCase

  test "memory script installer preserves resident edits across image upgrades" do
    output, error, result = Open3.capture3("python3", Rails.root.join("test/memory_script_install_test.py").to_s)
    assert result.success?, "#{output}\n#{error}"
  end

  test "invalid resident hook bytes are preserved privately and boot can continue" do
    [ "{ private broken json", "[]", '{"hooks":{"Stop":false}}', '{"hooks":{"Stop":[{"hooks":[null]}]}}' ].each do |original|
      Dir.mktmpdir do |dir|
        path = File.join(dir, "hooks.json")
        File.write(path, original)
        _, error, result = Open3.capture3("python3", Rails.root.join("agent-runtime/install_memory_hooks.py").to_s, path)
        assert result.success?, error
        backup = Dir.glob("#{path}.invalid-*").sole
        assert_equal original, File.read(backup)
        assert_equal 0600, File.stat(backup).mode & 0777
        assert_not_includes error, original
        hooks = JSON.parse(File.read(path)).fetch("hooks")
        assert_equal 1, hooks.fetch("BeforeTurn").length
        assert_equal 1, hooks.fetch("Stop").length
      end
    end
  end

  test "before turn skips every shim attempt including empty and failure notices" do
    script = Rails.root.join("agent-runtime/memory_before_turn.py").to_s
    [ "<mnemodyne-preview-attempted/>\n", "<mnemodyne-preview-attempted/>\nA memory" ].each do |notice|
      out, error, result = Open3.capture3("python3", script,
        stdin_data: { input_messages: [ { content: "Synthetic user turn\n<mnemodyne-command-reference/>\n#{notice}" } ] }.to_json)
      assert result.success?
      assert_empty out
      assert_empty error
    end
  end

  test "before turn supplies command reference even when graph preview is skipped or unavailable" do
    script = Rails.root.join("agent-runtime/memory_before_turn.py").to_s
    [ "<mnemodyne-preview-attempted/>", "A direct resident turn" ].each do |text|
      out, _error, result = Open3.capture3("python3", script,
        stdin_data: { input_messages: [ { content: text } ] }.to_json)
      assert result.success?
      context = JSON.parse(out).dig("hookSpecificOutput", "additionalContext")
      assert_includes context, "<mnemodyne-command-reference/>"
      assert_includes context, "house-memory --key YYYYMMDD-HHMM-shape-slug form"
      assert_includes context, '"target_id":"UUID"'
    end
  end

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

  test "completed reflection receipts do not invite another turn or write memories" do
    [ "no shape", "journaled: A small moment", "journaled: A small moment; graph pending" ].each do |receipt|
      Dir.mktmpdir do |dir|
        script = Rails.root.join("agent-runtime/stop_journal_reflex.py").to_s
        output, error, result = Open3.capture3({ "AGENT_IDENTITY_PATH" => dir }, "python3", script,
          stdin_data: { last_assistant_message: receipt }.to_json)
        assert result.success?
        assert_empty output
        assert_empty error
        trace = JSON.parse(File.read("#{dir}/memory/automation/state/stop-events.jsonl"))
        assert_equal false, trace.fetch("journal_invited")
        assert_empty Dir.glob("#{dir}/memory/daily-journals/*.md")
      end
    end
  end

  test "an entry appended during the turn switches the invitation to address-only" do
    Dir.mktmpdir do |dir|
      env = { "AGENT_IDENTITY_PATH" => dir }
      script = Rails.root.join("agent-runtime/stop_journal_reflex.py").to_s
      event = { last_assistant_message: "Synthetic meaningful turn" }
      # First turn: nothing on disk, full invitation.
      _, prompt, result = Open3.capture3(env, "python3", script, stdin_data: event.to_json)
      assert_equal 2, result.exitstatus
      assert_includes prompt, "decide whether the just-completed turn has narrative shape"
      # The resident journals by hand during the next turn. Make the previous
      # turn end three minutes ago so the new heading is unambiguously this turn's.
      trace = File.join(dir, "memory/automation/state/stop-events.jsonl")
      rows = File.readlines(trace).map { |l| JSON.parse(l) }
      rows.last["recorded_at"] = (Time.now - 180).iso8601(6)
      File.write(trace, rows.map(&:to_json).join("\n") + "\n")
      # The hook reads the system clock (local time), not Time.zone.
      today = Date.today
      journal = File.join(dir, "memory/daily-journals/#{today}.md")
      FileUtils.mkdir_p(File.dirname(journal))
      stamp = Time.now.strftime("%H:%M")
      File.write(journal, "# Daily Journal: #{today}\n\n## #{stamp} — A shape I kept\n\nbody\n")
      _, prompt, result = Open3.capture3(env, "python3", script, stdin_data: event.to_json)
      assert_equal 2, result.exitstatus
      assert prompt.start_with?("REFLECTION CONTINUATION — not a new trigger. Journal already written this turn")
      assert_includes prompt, "## #{stamp} — A shape I kept"
      assert_includes prompt, "identity://memory/daily-journals/#{today}.md##{stamp}"
      assert_includes prompt, "Do not write another entry"
      assert_includes prompt, "house-memory --key ENTRY-SHAPE-KEY form"
      assert_includes prompt, "<mnemodyne-command-reference/>"
      assert_not_includes prompt, "decide whether the just-completed turn has narrative shape"
      # An entry older than the last invitation does not count as this turn's.
      old_stamp = (Time.now - 40 * 60).strftime("%H:%M")
      File.write(journal, "# Daily Journal: #{today}\n\n## #{old_stamp} — Earlier\n\nbody\n")
      _, prompt, result = Open3.capture3(env, "python3", script, stdin_data: event.to_json)
      assert_equal 2, result.exitstatus
      assert_includes prompt, "decide whether the just-completed turn has narrative shape"
    end
  end

  test "an entry written inside the previous turn does not make the next turn address-only" do
    Dir.mktmpdir do |dir|
      env = { "AGENT_IDENTITY_PATH" => dir }
      script = Rails.root.join("agent-runtime/stop_journal_reflex.py").to_s
      event = { last_assistant_message: "Synthetic meaningful turn" }
      today = Date.today
      journal = File.join(dir, "memory/daily-journals/#{today}.md")
      FileUtils.mkdir_p(File.dirname(journal))
      # Turn N: invitation, then the resident journals in-turn, then the
      # continuation's answer row lands (stop_hook_active: true).
      _, _, result = Open3.capture3(env, "python3", script, stdin_data: event.to_json)
      assert_equal 2, result.exitstatus
      stamp = Time.now.strftime("%H:%M")
      File.write(journal, "# Daily Journal: #{today}\n\n## #{stamp} — Written in turn N\n\nbody\n")
      _, out, result = Open3.capture3(env, "python3", script, stdin_data: event.merge(stop_hook_active: true).to_json)
      assert result.success?
      assert_empty out
      # Turn N+1 wrote nothing: it must get the full invitation, not "already written".
      _, prompt, result = Open3.capture3(env, "python3", script, stdin_data: event.to_json)
      assert_equal 2, result.exitstatus
      assert_includes prompt, "decide whether the just-completed turn has narrative shape"
      assert_not_includes prompt, "Journal already written this turn"
    end
  end

  test "stop reflex automatically invites journal then source linked formation only once" do
    Dir.mktmpdir do |dir|
      env = { "AGENT_IDENTITY_PATH" => dir }
      script = Rails.root.join("agent-runtime/stop_journal_reflex.py").to_s
      event = { last_assistant_message: "Synthetic meaningful turn" }
      _, prompt, result = Open3.capture3(env, "python3", script, stdin_data: event.to_json)
      assert_equal 2, result.exitstatus
      assert_includes prompt, "house-memory --key ENTRY-SHAPE-KEY form"
      assert_includes prompt, "If you journaled, index it"
      assert_includes prompt, "reuse them rather than creating duplicates"
      assert_includes prompt, "Do not repeat or resend that reply"
      assert_includes prompt, "Do not send this reflection or its receipt"
      assert_includes prompt, "internal reflection continuation"
      assert_includes prompt, "never_automatic"
      assert_includes prompt, "graph pending"
      assert_includes prompt, '"connections"'
      assert_includes prompt, "no shape"
      assert_includes prompt, "identity://memory/daily-journals/"
      assert prompt.start_with?("REFLECTION CONTINUATION — not a new trigger"), "The continuation must announce itself before any re-delivery guard reads it"
      assert_includes prompt, "Re-delivery, duplicate-tick and already-answered checks"
      assert_includes prompt, "reusing your named hubs or creating the missing ones"
      assert_includes prompt, "\"node_type\":\"person\""
      assert_includes prompt, "Never invent a person or need"
      assert_includes prompt, "surfaced_need"
      _, prompt, result = Open3.capture3(env, "python3", script, stdin_data: event.merge(stop_hook_active: true).to_json)
      assert result.success?
      assert_empty prompt
      assert_empty Dir.glob("#{dir}/memory/daily-journals/*.md"), "The hook must not manufacture a journal"
    end
  end

end

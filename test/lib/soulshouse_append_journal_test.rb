require "test_helper"
require "open3"
require "tmpdir"
require "timeout"

class SoulshouseAppendJournalTest < ActiveSupport::TestCase

  SCRIPT = Rails.root.join("agent-runtime/soulshouse-append-journal")

  test "rejects empty stdin without creating a journal" do
    Dir.mktmpdir do |identity_path|
      stdout, stderr, status = run_helper(identity_path, stdin_data: "")

      assert_not status.success?
      assert_empty stdout
      assert_includes stderr, "empty body on stdin; nothing written"
      assert_not Dir.exist?(File.join(identity_path, "memory"))
    end
  end

  test "rejects whitespace-only stdin without changing an existing journal" do
    Dir.mktmpdir do |identity_path|
      journal = journal_path(identity_path)
      FileUtils.mkdir_p(File.dirname(journal))
      File.write(journal, "# Existing journal\n")

      _stdout, stderr, status = run_helper(identity_path, stdin_data: " \n\t\n")

      assert_not status.success?
      assert_includes stderr, "empty body on stdin; nothing written"
      assert_equal "# Existing journal\n", File.read(journal)
    end
  end

  test "appends a non-empty body and reports the journal path" do
    Dir.mktmpdir do |identity_path|
      stdout, stderr, status = run_helper(
        identity_path,
        "A small shape",
        stdin_data: "First paragraph.\n\nSecond paragraph.\n"
      )

      assert status.success?, stderr
      assert_equal "#{journal_path(identity_path)}\n", stdout
      assert_match(%r{journal entry appended: identity://memory/daily-journals/#{Date.current}\.md#\d{2}:\d{2}}, stderr)
      assert_includes stderr, "house-memory --key ENTRY-SHAPE-KEY form"
      assert_includes stderr, "retry the same key and JSON"

      contents = File.read(journal_path(identity_path))
      assert_includes contents, "# Daily Journal: #{Date.current}"
      assert_match(/## \d{2}:\d{2} — A small shape/, contents)
      assert_includes contents, "First paragraph.\n\nSecond paragraph.\n"
    end
  end

  test "file body and explicit date and time preserve the full journal address" do
    Dir.mktmpdir do |identity_path|
      body = File.join(identity_path, "body with spaces.md")
      File.write(body, "Quotes ' \" and $dollars and `ticks`\n\nSecond paragraph.\n")
      journal = File.join(identity_path, "memory/daily-journals/2024-02-29.md")
      FileUtils.mkdir_p(File.dirname(journal))
      File.write(journal, "# Daily Journal: 2024-02-29\n\nEarlier entry\n")

      stdout, stderr, status = run_helper(
        identity_path, "--file", body, "--date", "2024-02-29", "--at", "23:59", "Late",
        stdin_data: "IGNORE STDIN"
      )

      assert status.success?, stderr
      assert_equal "#{journal}\n", stdout
      assert_includes stderr, "identity://memory/daily-journals/2024-02-29.md#23:59"
      assert_equal "# Daily Journal: 2024-02-29\n\nEarlier entry\n\n## 23:59 — Late\n\n#{File.read(body)}", File.read(journal)
      assert_not File.exist?(journal_path(identity_path))

      _stdout, stderr, status = run_helper(
        identity_path, "--file=#{body}", "--date=2024-02-29", "--at=00:00", "--", "-Title",
        stdin_data: ""
      )
      assert status.success?, stderr
      assert_includes File.read(journal), "## 00:00 — -Title"
      assert_equal 1, File.read(journal).scan("# Daily Journal:").length
    end
  end

  test "invalid options exit without reading stdin or creating a journal" do
    invalid = [
      [ "--file=" ], [ "--file", "" ], [ "--file" ],
      [ "--at=" ], [ "--at", "" ], [ "--at" ],
      [ "--date=" ], [ "--date", "" ], [ "--date" ],
      [ "--unknown" ], [ "one", "two" ], [ "one", "--", "two" ]
    ]
    %w[7:05 24:00 07:60 0705 aa:bb].each { |time| invalid << [ "--at", time ] }
    %w[2019-3-4 20190304 ../../bad 2026-00-01 2026-13-01 2026-19-39
       2026-01-00 2026-02-29 2026-02-30 2026-04-31].each { |date| invalid << [ "--date", date ] }

    Dir.mktmpdir do |identity_path|
      invalid.each do |arguments|
        Open3.popen3({ "AGENT_IDENTITY_PATH" => identity_path }, "sh", SCRIPT.to_s, *arguments) do |stdin, stdout, stderr, wait|
          begin
            # Leave stdin open: a parser that falls back to cat would block.
            status = Timeout.timeout(3) { wait.value }
            assert_equal 1, status.exitstatus, arguments.inspect
            assert_empty stdout.read
            assert_includes stderr.read, "soulshouse-append-journal:"
          rescue Timeout::Error
            Process.kill("TERM", wait.pid)
            flunk "Invalid options waited for stdin: #{arguments.inspect}"
          ensure
            stdin.close
          end
        end
        assert_not Dir.exist?(File.join(identity_path, "memory"))
      end
    end
  end

  test "invalid body files leave existing journals unchanged" do
    Dir.mktmpdir do |identity_path|
      journal = journal_path(identity_path)
      FileUtils.mkdir_p(File.dirname(journal))
      File.write(journal, "Existing contents\n")
      empty = File.join(identity_path, "empty.md")
      File.write(empty, " \n\t\n")

      [ empty, identity_path, File.join(identity_path, "missing.md") ].each do |body|
        stdout, _stderr, status = run_helper(identity_path, "--file", body, stdin_data: "Must not fall back")
        assert_not status.success?
        assert_empty stdout
        assert_equal "Existing contents\n", File.read(journal)
      end
    end
  end

  private

  def run_helper(identity_path, *arguments, stdin_data:)
    Open3.capture3(
      { "AGENT_IDENTITY_PATH" => identity_path },
      "sh",
      SCRIPT.to_s,
      *arguments,
      stdin_data: stdin_data
    )
  end

  def journal_path(identity_path)
    File.join(identity_path, "memory/daily-journals/#{Date.current}.md")
  end

end

require "test_helper"
require "open3"
require "tmpdir"

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

      contents = File.read(journal_path(identity_path))
      assert_includes contents, "# Daily Journal: #{Date.current}"
      assert_match(/## \d{2}:\d{2} — A small shape/, contents)
      assert_includes contents, "First paragraph.\n\nSecond paragraph.\n"
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

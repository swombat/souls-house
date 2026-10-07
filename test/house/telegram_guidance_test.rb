require "test_helper"

class TelegramGuidanceTest < ActiveSupport::TestCase

  test "active supporting guides do not revive the retired title convention" do
    paths = Rails.root.glob("agent-runtime/docs/**/*.md") +
      Rails.root.glob("docs/**/*.md").reject { |path| path.to_s.include?("/.bak/") } +
      [ Rails.root.join("AGENTS.md") ]

    paths.each do |path|
      refute_includes path.read, "[AGENT-ONLY]", path.relative_path_from(Rails.root).to_s
    end
  end

  test "resident instructions and API manual describe a separate Telegram channel" do
    %w[runtime-instructions soulshouse-api].each do |name|
      guide = Rails.root.join("agent-runtime/docs/#{name}.md").read
      assert_includes guide, "automatic Telegram"
      assert_includes guide, "direct-message channel"
      refute_includes guide, "Telegram notifications\nare queued"
    end
  end

end

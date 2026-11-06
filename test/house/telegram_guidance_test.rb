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

end

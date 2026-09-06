require "test_helper"

class RuntimeCommandPreviewTest < ActiveSupport::TestCase

  test "production image packages the shared policy in build and final stages" do
    dockerfile = Rails.root.join("Dockerfile").read
    assert_includes dockerfile, "COPY agent-runtime/command_preview_policy.json agent-runtime/command_preview_policy.json"
    assert_includes dockerfile, "COPY --from=build --chown=rails:rails /rails/agent-runtime /rails/agent-runtime"
  end

  test "ordinary paths and search arguments survive" do
    [ "git status --short", "cat app/models/agent.rb", "ls -la /home/agent",
      "bundle exec rails test test/models/agent_test.rb", "grep -n runtime app/services/agent_dispatch.rb",
      'rg "two words" app', "cd /home/agent && ls -la" ].each do |preview|
      assert_equal preview, RuntimeCommandPreview.validated(preview)
    end
    [ nil, {}, "git status\n--short", "git status\t--short",
      "git status \e[31m", "git status\u202eSECRET",
      "git status " + "--short " * 300 ].each do |preview|
      assert_nil RuntimeCommandPreview.validated(preview), preview.inspect
    end
  end

  test "server redacts credential fields and script bodies independently" do
    [ "curl --token SECRET", 'curl -H "Authorization: Bearer SECRET"',
      "curl https://user:SECRET@example.test/status?token=SECRET",
      "python3 -c SECRET", "ruby -eSECRET", "echo password=SECRET",
      "curl --data SECRET", "env KEY=SECRET git status", "echo Bearer SECRET",
      "curl -uuser:SECRET", "bash -lc SECRET", "node --eval=SECRET", "awk SECRET file" ].each do |preview|
      assert_not_includes RuntimeCommandPreview.validated(preview), "SECRET"
    end
    assert_equal "curl --token [REDACTED]", RuntimeCommandPreview.validated("curl --token SECRET")
  end

end

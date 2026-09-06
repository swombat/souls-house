require "test_helper"

class RuntimeCommandPreviewTest < ActiveSupport::TestCase

  test "only finite vocabulary previews are accepted" do
    [ "git status --short", "curl [arguments hidden]", "Command [arguments hidden]",
      "bundle exec rails test [arguments hidden]", "git diff --stat" ].each do |preview|
      assert_equal preview, RuntimeCommandPreview.validated(preview)
    end
    [ nil, {}, "curl --token SECRET", "git status SECRET", "cat /private/SECRET",
      "git status\n--short", "git status\t--short", " git status", "git status ",
      "git status \e[31m", "<script>alert(1)</script>", "git status\u202eSECRET",
      "git status " + "--short " * 100 ].each do |preview|
      assert_nil RuntimeCommandPreview.validated(preview), preview.inspect
    end
  end

end

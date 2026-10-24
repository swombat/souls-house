require "test_helper"
require "open3"

class SilenceNudgeTest < ActiveSupport::TestCase

  test "synthetic Python silence clock and mid-turn notice delivery" do
    output, status = Open3.capture2e("python3", Rails.root.join("test/silence_nudge_test.py").to_s)
    assert status.success?, output
  end

end

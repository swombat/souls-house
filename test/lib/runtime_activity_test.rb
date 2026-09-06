require "test_helper"
require "open3"

class RuntimeActivityTest < ActiveSupport::TestCase

  test "synthetic Python reporter contract and process supervision" do
    output, status = Open3.capture2e("python3", Rails.root.join("test/runtime_activity_test.py").to_s)
    assert status.success?, output
  end

end

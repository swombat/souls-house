require "test_helper"
require "open3"

# The standalone suite uses an in-process urllib mock, never a live CRM.
class SoulshouseTwentyTest < ActiveSupport::TestCase
  test "resident Twenty helper offline contracts and credential safety" do
    env = { "PATH" => ENV.fetch("PATH"), "PYTHONDONTWRITEBYTECODE" => "1" }
    out, err, status = Open3.capture3(
      env, "python3", Rails.root.join("test/soulshouse_twenty_test.py").to_s,
      unsetenv_others: true
    )
    assert status.success?, "#{out}\n#{err}"
  end
end

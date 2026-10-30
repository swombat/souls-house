require "test_helper"
require "open3"

class SoulshouseOdooTest < ActiveSupport::TestCase
  test "read-only Odoo helper synthetic contract and security tests" do
    output, status = Open3.capture2e(
      { "PATH" => ENV.fetch("PATH") },
      "python3", Rails.root.join("test/soulshouse_odoo_test.py").to_s,
      unsetenv_others: true
    )
    assert status.success?, output
  end
end

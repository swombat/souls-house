require "test_helper"

# Fixture loads skip Rails' foreign-key validation (config/environments/test.rb)
# because it scans every constraint on every load. Fixtures are inserted with
# triggers disabled, so they are the only rows that can break a foreign key;
# this checks them once, the way the load used to.
class FixtureForeignKeysTest < ActiveSupport::TestCase

  test "the loaded fixtures satisfy every foreign key" do
    assert_nothing_raised { ActiveRecord::Base.connection.check_all_foreign_keys_valid! }
  end

end

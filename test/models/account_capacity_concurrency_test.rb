require "test_helper"

class AccountCapacityConcurrencyTest < ActiveSupport::TestCase

  self.use_transactional_tests = false

  test "concurrent creators cannot both take the final account place" do
    setting = Setting.instance
    old_limit = setting.max_accounts
    prefix = "capacity-race-#{SecureRandom.hex(6)}"
    setting.update!(max_accounts: Account.count + 1)
    ready = Queue.new
    start = Queue.new
    workers = 2.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Current.reset
          # Prime the query cache before either writer gets the admission lock.
          Account.cache do
            Account.count
            ready << true
            start.pop
            account = Account.new(name: "#{prefix}-#{index}", account_type: :team)
            account.save ? :created : :blocked
          end
        ensure
          Current.reset
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    assert_equal [ :blocked, :created ], workers.map(&:value).sort
    assert_equal 1, Account.where("name LIKE ?", "#{prefix}%").count
  ensure
    workers&.each(&:join)
    Account.where("name LIKE ?", "#{prefix}%").find_each(&:destroy!) if prefix
    setting&.update!(max_accounts: old_limit) if old_limit
  end

end

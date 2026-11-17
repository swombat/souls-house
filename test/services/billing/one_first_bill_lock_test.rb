require "test_helper"
require "support/fake_stripe"

# The real lock (no fixture transaction): while one start holds the account's
# billing lock, another opens nothing and says billing is busy. With
# OneFirstBillTest (the second start, run after, sees the first and waits),
# two first bills started in the same moment end as one subscription.
class Billing::OneFirstBillLockTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  self.use_transactional_tests = false

  setup do
    # FakeStripe::Helpers runs unit contracts as the lock's holder; this test
    # is about the lock itself, so it takes the real one back.
    Billing::CheckoutLock.define_singleton_method(:synchronize_residents, @saved_residents_lock)
    @setting = Setting.instance
    @allow_agents = @setting.allow_agents
    @setting.update!(allow_agents: true)
    @account = accounts(:personal_account)
    @billing_required = @account.billing_required
    @account.update!(billing_required: true)
    @stripe = FakeStripe.new
    @customer = BillingCustomer.create!(account: @account, stripe_customer_id: "cus_lock_#{SecureRandom.hex(4)}")
    @stripe.put_payment_method("pm_visa")
    @stripe.put_customer(@customer.stripe_customer_id, default_payment_method: "pm_visa")
  end

  teardown do
    ResidentBirthOrder.where(account: @account).delete_all
    @customer&.delete
    @account.update_columns(billing_required: @billing_required)
    @setting.update_columns(allow_agents: @allow_agents)
  end

  test "while another start holds the account's lock, a second opens nothing and says billing is busy" do
    held = Queue.new
    release = Queue.new
    holder = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        Billing::CheckoutLock.synchronize_residents(@account) do
          held << true
          release.pop
        end
      end
    end
    held.pop
    error = assert_raises(Billing::NotReady) do
      Billing::PaidBirth.new(client: @stripe).start!(account: @account, creator: users(:user_1), open_beginning: true,
        tier: Billing::Tier.find!("conversation"), attributes: { name: "Bea", system_prompt: "", model_id: "openrouter/auto" })
    end
    assert_match(/busy/, error.message)
    assert_empty @stripe.instance_variable_get(:@subscriptions)
    assert_not ResidentBirthOrder.exists?(account: @account)
  ensure
    release << true
    holder&.join
  end

end

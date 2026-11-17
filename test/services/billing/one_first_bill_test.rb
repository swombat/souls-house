require "test_helper"
require "support/fake_stripe"

# One first bill per account (Build C, A's leftover): each start settles only
# its own creator's earlier order, so two people starting first bills used to
# open two subscriptions. A second person's first bill now waits for the first.
class Billing::OneFirstBillTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  setup do
    Setting.instance.update!(allow_agents: true)
    @account = accounts(:personal_account)
    @account.update!(billing_required: true)
    @owner = users(:user_1)
    @other = users(:site_admin_user)
    @stripe = FakeStripe.new
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
    @stripe.put_payment_method("pm_visa")
    @stripe.put_customer("cus_1", default_payment_method: "pm_visa")
    @tier = Billing::Tier.find!("conversation")
  end

  def paid_birth = Billing::PaidBirth.new(client: @stripe)

  def start!(creator, name)
    paid_birth.start!(account: @account, creator:, open_beginning: true, tier: @tier,
      attributes: { name:, system_prompt: "", model_id: "openrouter/auto" })
  end

  def subscriptions = @stripe.instance_variable_get(:@subscriptions).values

  test "a second person's first bill is refused while the first waits to be paid: one subscription" do
    order, = start!(@owner, "Aria")
    assert order.pending?
    assert_equal 1, subscriptions.size
    error = assert_raises(Billing::PaidBirth::Refused) { start!(@other, "Bea") }
    assert_match(/already started its first bill/, error.message)
    assert_equal 1, subscriptions.size, "no second subscription"
  end

  test "the free trial is refused the same way" do
    start!(@owner, "Aria")
    error = assert_raises(Billing::PaidBirth::Refused) do
      paid_birth.start_trial!(account: @account, creator: @other, open_beginning: true,
        attributes: { name: "Bea", system_prompt: "", model_id: "openrouter/auto" },
        success_url: "https://house.test/ok", cancel_url: "https://house.test/no")
    end
    assert_match(/already started its first bill/, error.message)
  end

  # Negative control: the same person starting again replaces their own order
  # (settle_earlier!), as before; only someone else's waiting bill refuses.
  test "the same person starting again is not refused by their own waiting order" do
    start!(@owner, "Aria")
    second, = start!(@owner, "Aria")
    assert second.pending?
  end

end

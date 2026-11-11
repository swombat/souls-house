require "test_helper"
require "support/fake_stripe"

# Manage billing on a bill several residents share (eoXAEj, Mira emmNyb): a
# portal that can cancel ends all of them, so such a session names a
# configuration read now and found safe, or isn't made.
class Billing::PortalTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  setup do
    @a = agents(:research_assistant)
    @b = agents(:code_reviewer)
    @account = @a.account
    @stripe = FakeStripe.new
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
  end

  def url = Billing::Portal.new(account: @account, return_url: "https://house.test/billing", client: @stripe).url

  def shared!(status: "active")
    @stripe.put_shared_subscription(id: "sub_acct", account: @account, customer: "cus_1", status: status,
      items: [ { agent: @a, price: CONVERSATION_PRICE }, { agent: @b, price: LIFE_PRICE } ])
  end

  test "one resident per subscription: the session opens on Stripe's default configuration, as before" do
    @stripe.put_subscription(id: "sub_a", agent: @a, customer: "cus_1", price: CONVERSATION_PRICE, status: "active")
    @stripe.put_subscription(id: "sub_b", agent: @b, customer: "cus_1", price: LIFE_PRICE, status: "active")

    assert_equal "https://billing.stripe.com/p/session/test_1", url
    assert_not @stripe.portal_sessions.sole.key?(:configuration)
  end

  test "a shared bill with only the default (cancel and switching on) gets no session" do
    shared!
    @stripe.put_portal_configuration(prices: [ CONVERSATION_PRICE ])

    error = assert_raises(Billing::Portal::Restricted) { url }
    assert_match(/end all of them at once/, error.message)
    assert_empty @stripe.portal_sessions
  end

  test "a shared bill opens on the configuration with cancel and switching off, card and invoices on" do
    shared!
    @stripe.put_portal_configuration(prices: [ CONVERSATION_PRICE ])
    @stripe.put_portal_configuration(enabled: false, cancel: false, card_update: false)
    @stripe.put_portal_configuration(enabled: false, cancel: false, active: false)
    @stripe.put_portal_configuration(enabled: false, cancel: false, invoices: false)
    @stripe.put_portal_configuration(enabled: false, cancel: true)
    @stripe.put_portal_configuration(enabled: false, cancel: false)

    url
    assert_equal "bpc_test_6", @stripe.portal_sessions.sole[:configuration]
  end

  test "the safe configuration is found past the first page" do
    shared!
    @stripe.put_portal_configuration(prices: [ CONVERSATION_PRICE ])
    @stripe.put_portal_configuration(enabled: false, cancel: false)
    @stripe.portal_page_size!(1)

    url
    assert_equal "bpc_test_2", @stripe.portal_sessions.sole[:configuration]
  end

  test "an ended shared subscription doesn't restrict; a past-due or trialing one does" do
    shared!(status: "canceled")
    @stripe.put_portal_configuration(prices: [])
    url
    assert_not @stripe.portal_sessions.last.key?(:configuration)

    %w[past_due trialing incomplete unpaid].each do |status|
      shared!(status: status)
      assert_raises(Billing::Portal::Restricted, status) { url }
    end
  end

  test "a shared subscription on a later page of the customer's subscriptions is found" do
    shared!
    6.times do |index|
      agent = index.even? ? @a : @b
      @stripe.put_subscription(id: "sub_old_#{index}", agent: agent, customer: "cus_1", price: CONVERSATION_PRICE, status: "canceled")
    end
    @stripe.put_portal_configuration(prices: [])
    @stripe.subscriptions_page_size!(2)

    assert_raises(Billing::Portal::Restricted) { url }
  end

  test "subscriptions that can't be read open nothing, never the default" do
    @stripe.put_portal_configuration(prices: [])
    @stripe.subscriptions_list_fails!(Stripe::APIConnectionError.new("timed out"))

    assert_raises(Stripe::APIConnectionError) { url }
    assert_empty @stripe.portal_sessions
  end

end

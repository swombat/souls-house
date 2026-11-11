require "test_helper"
require "support/fake_stripe"

# Manage billing never opens a portal that can cancel or switch a
# subscription (eoXAEj, Mira emmNyb and JaMKqg): residents share one bill,
# and an account with one resident today can have two by the time an open
# portal page is used. Every session names a configuration read now and
# found safe, or none is made.
class Billing::PortalTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  setup do
    @agent = agents(:research_assistant)
    @account = @agent.account
    @stripe = FakeStripe.new
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
  end

  def url = Billing::Portal.new(account: @account, return_url: "https://house.test/billing", client: @stripe).url

  def safe!(**) = @stripe.put_portal_configuration(enabled: false, cancel: false, **)

  test "only Stripe's default (cancel and switching on): no session, for a one-resident account too" do
    @stripe.put_subscription(id: "sub_a", agent: @agent, customer: "cus_1", price: CONVERSATION_PRICE, status: "active")
    @stripe.put_portal_configuration(prices: [ CONVERSATION_PRICE ])

    error = assert_raises(Billing::Portal::Restricted) { url }
    assert_match(/write to/, error.message)
    assert_empty @stripe.portal_sessions
  end

  test "the session names the configuration with cancel and switching off and card and invoices on" do
    @stripe.put_portal_configuration(prices: [ CONVERSATION_PRICE ])
    safe!(card_update: false)
    safe!(active: false)
    safe!(invoices: false)
    @stripe.put_portal_configuration(enabled: false, cancel: true)
    @stripe.put_portal_configuration(enabled: true, allowed: %w[quantity], cancel: false)
    safe!

    assert_equal "https://billing.stripe.com/p/session/test_1", url
    session = @stripe.portal_sessions.sole
    assert_equal "bpc_test_7", session[:configuration]
    assert_equal "cus_1", session[:customer]
  end

  test "a flag Stripe didn't send counts as on" do
    @stripe.put_portal_configuration(enabled: false, cancel: nil)
    @stripe.put_portal_configuration(enabled: nil, cancel: false)

    assert_raises(Billing::Portal::Restricted) { url }
  end

  test "the safe configuration is found past the first page, and an empty page claiming more ends the search" do
    @stripe.put_portal_configuration(prices: [])
    safe!
    @stripe.portal_page_size!(1)
    url
    assert_equal "bpc_test_2", @stripe.portal_sessions.sole[:configuration]

    @stripe.portal_page_size!(0)
    assert_raises(Billing::Portal::Restricted) { url }
  end

end

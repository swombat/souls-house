require "test_helper"
require "webmock/minitest"

class Billing::ClientTest < ActiveSupport::TestCase
  test "SDK upgrades retain the reviewed billing API version" do
    Billing.stub(:secret_key, "sk_test_fake") do
      request = stub_request(:get, "https://api.stripe.com/v1/customers/cus_version_test")
        .with(headers: { "Stripe-Version" => "2026-09-30.endive", "Authorization" => "Bearer sk_test_fake" })
        .to_return(status: 200, body: '{"id":"cus_version_test","object":"customer"}',
          headers: { "Content-Type" => "application/json" })

      assert_equal "cus_version_test", Billing.client.v1.customers.retrieve("cus_version_test").id
      assert_requested request
    end
  end
end

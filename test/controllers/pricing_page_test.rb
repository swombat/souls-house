require "test_helper"
require "support/fake_stripe"

# /pricing is public and must stay true with no Stripe keys configured.
class PricingPageTest < ActionDispatch::IntegrationTest

  STRIPE_KEYS = FakeStripe::Helpers::STRIPE_ENV.keys

  test "renders signed out with no Stripe keys, every plan unpurchasable" do
    without_stripe_env do
      get pricing_path

      assert_response :success
      assert_equal "pricing", inertia_component
      props = inertia_shared_props
      assert_equal false, props["billing_open"]
      assert_equal Billing::Tier.all.map(&:id), props["tiers"].map { |tier| tier["id"] }
      assert props["tiers"].none? { |tier| tier["purchasable"] }
      assert_match(/@/, props["contact_email"])
    end
  end

  test "plan cards carry the catalogue's prices and allowances, and no container sizes" do
    without_stripe_env do
      get pricing_path

      tiers = inertia_shared_props["tiers"]
      Billing::Tier.all.each do |tier|
        card = tiers.find { |row| row["id"] == tier.id }
        assert_equal tier.name, card["name"]
        assert_equal tier.monthly_usd, card["monthly_usd"]
        assert_equal tier.allowance_usd, card["allowance_usd"]
      end
      assert tiers.none? { |row| row.key?("memory_gb") || row.key?("cpu_shares") }
    end
  end

  test "renders signed in" do
    user = users(:user_1)
    post login_path, params: { email_address: user.email_address, password: "password123" }

    without_stripe_env do
      get pricing_path

      assert_response :success
      assert_equal "pricing", inertia_component
    end
  end

  test "shows priced plans as open once Stripe is configured" do
    with_stripe_env do
      get pricing_path

      assert inertia_shared_props["billing_open"]
      assert inertia_shared_props["tiers"].all? { |tier| tier["purchasable"] }
    end
  end

  test "is not linked from the header or footer" do
    navigation = Rails.root.join("app/frontend/lib/components/navigation")
    Dir[navigation.join("**/*.svelte")].each do |file|
      assert_no_match %r{/pricing\b}, File.read(file), "#{file} links /pricing"
    end
  end

  private

  def without_stripe_env(&)
    swap_env(STRIPE_KEYS.index_with { nil }, &)
  end

  def with_stripe_env(&)
    swap_env(FakeStripe::Helpers::STRIPE_ENV, &)
  end

  def swap_env(values)
    saved = values.keys.index_with { |key| ENV[key] }
    values.each { |key, value| ENV[key] = value }
    # Only the Stripe credentials disappear; everything else reads as normal.
    credentials = Rails.application.credentials
    dig = credentials.method(:dig)
    credentials.stub(:dig, ->(*keys) { keys.first == :stripe ? nil : dig.call(*keys) }) { yield }
  ensure
    saved.each { |key, value| ENV[key] = value }
  end

end

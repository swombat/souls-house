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

  test "plan cards carry the catalogue's prices, allowances and what each plan includes" do
    without_stripe_env do
      get pricing_path

      tiers = inertia_shared_props["tiers"]
      Billing::Tier.all.each do |tier|
        card = tiers.find { |row| row["id"] == tier.id }
        assert_equal tier.name, card["name"]
        assert_equal tier.size, card["size"]
        assert_equal Billing.usd(tier.monthly_usd), card["monthly_usd"]
        assert_equal Billing.usd(tier.allowance_usd), card["allowance_usd"]
        assert_equal tier.features.stringify_keys, card["features"]
      end
      assert_equal %w[conversation life work], tiers.map { |row| row["id"] }
      assert_equal %w[9.99 19.99 49.99], tiers.map { |row| row["monthly_usd"] }
      assert tiers.none? { |row| row.key?("memory_gb") || row.key?("cpu_shares") }, "container limits stay server-side"
      # Going live (Daniel, 2026-10-25): a size shows only what it delivers
      # today. Swarm searches and sub-agents are the account plan's.
      tiers.each do |row|
        assert_equal %w[allowance_usd hosting], row["features"].keys.sort, row["id"]
      end
    end
  end

  test "account plans lead with what an account pays at least, never Companions' $0" do
    without_stripe_env do
      get pricing_path

      plans = inertia_shared_props["account_plans"]
      assert_equal %w[companions partners colleagues], plans.map { |plan| plan["id"] }
      assert_equal %w[9.99 29.99 59.99], plans.map { |plan| plan["from_usd"] }
      assert_equal({ "members" => "several", "swarm_searches" => 100, "subagents" => true }, plans.last["features"])
      assert plans.none? { |plan| plan["purchasable"] }
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

  # Linked once plans went live (Daniel, 2026-10-25); the footer, not the header.
  test "is linked from the footer" do
    footer = Rails.root.join("app/frontend/lib/components/navigation/Footer.svelte").read
    assert_match %r{href="/pricing"}, footer
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

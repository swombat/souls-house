require "test_helper"

class Billing::TierTest < ActiveSupport::TestCase

  test "three plans, each on a machine the house can buy" do
    assert_equal %w[conversation life work], Billing::Tier.all.map(&:id)
    assert_equal [ 20, 50, 100 ], Billing::Tier.all.map(&:monthly_usd)
    Billing::Tier.all.each do |tier|
      assert_includes CloudProcurementOperation::SERVER_TYPES, tier.server_type
      assert tier.machine[:ram_gb].positive?
    end
  end

  test "Life and Work include swarm search, Work the most" do
    assert_equal %w[life work], Billing::Tier.with_swarm_search.map(&:id)
    assert_equal 20, Billing::Tier.find!("life").swarm_searches
    assert_equal 100, Billing::Tier.find!("work").swarm_searches
  end

  test "Conversation connects to nothing outside; Life and Work to every connection" do
    assert_empty Billing::Tier.find!("conversation").connections
    assert_equal Billing::Tier::CONNECTIONS, Billing::Tier.find!("life").connections
    assert_equal Billing::Tier::CONNECTIONS, Billing::Tier.find!("work").connections
  end

  # Costed 2026-10-14 (WjNvXj/YwkgkY). Machine at €1 = $1.10, Scribe $0.22/h,
  # S3 $0.023/GB, swarm $0.064 a search, Stripe 2.9% + $0.30. If a plan's
  # numbers change, this keeps the at-full-use margin positive.
  test "every plan keeps a positive margin at full use" do
    machine_eur = { "cx23" => 6.59, "cx33" => 10.19, "cx43" => 19.19 }
    Billing::Tier.all.each do |tier|
      cost = machine_eur.fetch(tier.server_type) * 1.10 +
        tier.allowance_usd +
        tier.transcription_hours * 0.22 +
        tier.backup_gb * 0.023 +
        tier.swarm_searches * 0.064 +
        tier.monthly_usd * 0.029 + 0.30
      assert cost < tier.monthly_usd, "#{tier.name} costs $#{cost.round(2)} at full use against $#{tier.monthly_usd}"
    end
  end

end

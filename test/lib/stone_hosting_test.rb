require "test_helper"

class StoneHostingTest < ActiveSupport::TestCase

  test "domain must be separate registrable hostname" do
    old_domain, old_house = ENV.values_at("SOULSHOUSE_STONES_DOMAIN", "SOULSHOUSE_DOMAIN")
    ENV["SOULSHOUSE_DOMAIN"] = "house.test"
    [ "house.test", "stones.house.test", "https://soulstones.test", "soulstones.test:443", "*.soulstones.test" ].each do |domain|
      ENV["SOULSHOUSE_STONES_DOMAIN"] = domain
      assert_raises(StoneHosting::InvalidConfiguration, domain) { StoneHosting.validate! }
    end
    ENV["SOULSHOUSE_STONES_DOMAIN"] = "soulstones.test"
    assert_nil StoneHosting.validate!
    ENV.delete("SOULSHOUSE_DOMAIN")
    assert_raises(StoneHosting::InvalidConfiguration) { StoneHosting.validate! }
    ENV["SOULSHOUSE_DOMAIN"] = "house.test"
    assert StoneHosting.content_host?("anything.soulstones.test")
    refute StoneHosting.content_host?("evil-soulstones.test")
    assert_nil StoneHosting.name("nested.mystic-shadow-blur.soulstones.test")
  ensure
    ENV["SOULSHOUSE_STONES_DOMAIN"], ENV["SOULSHOUSE_DOMAIN"] = old_domain, old_house
  end

end

require "test_helper"

class HetznerAvailabilitySampleTest < ActiveSupport::TestCase

  def check(at, available = {})
    HetznerAvailabilitySample.record!(
      HetznerAvailabilitySample::TYPES.index_with { |type| %w[fsn1 nbg1].index_with { |loc| Array(available[type]).include?(loc) } },
      at:
    )
  end

  test "a pair is up when either type is available anywhere, down when neither is, nil when unchecked" do
    t0 = Time.zone.parse("2026-11-13 09:00")
    check(t0)                                  # nothing
    check(t0 + 5.minutes, "cax11" => %w[nbg1]) # only the ARM sibling
    check(t0 + 10.minutes, "cx23" => %w[fsn1 nbg1], "cx53" => %w[fsn1])
    HetznerAvailabilitySample.record_failure!("unavailable", at: t0 + 15.minutes)

    series = HetznerAvailabilitySample.pair_series(t0 - 1.minute).index_by { |line| line[:label] }

    assert_equal [ "CX23 + CAX11", "CX33 + CAX21", "CX43 + CAX31", "CX53 + CAX41" ], series.keys
    assert_equal [ 0, 1, 1, nil ], series["CX23 + CAX11"][:points].map(&:last)
    assert_equal [ 0, 0, 0, nil ], series["CX33 + CAX21"][:points].map(&:last)
    assert_equal [ 0, 0, 1, nil ], series["CX53 + CAX41"][:points].map(&:last)
    assert_equal [ t0, t0 + 5.minutes, t0 + 10.minutes, t0 + 15.minutes ], series["CX43 + CAX31"][:points].map(&:first)
  end

  test "the series starts at the window, not before" do
    t0 = Time.zone.parse("2026-11-01 09:00")
    check(t0, "cx23" => %w[fsn1])
    check(t0 + 8.days)

    points = HetznerAvailabilitySample.pair_series(t0 + 1.day).first[:points]
    assert_equal [ [ t0 + 8.days, 0 ] ], points
  end

  test "recent checks list available locations per type, newest first, and say when a check failed" do
    t0 = Time.zone.parse("2026-11-13 09:00")
    check(t0, "cx33" => %w[nbg1 fsn1])
    HetznerAvailabilitySample.record_failure!("unavailable", at: t0 + 5.minutes)

    newest, older = HetznerAvailabilitySample.recent_checks(100)

    assert_equal t0 + 5.minutes, newest[:at]
    assert_equal({ available: [], error: "unavailable" }, newest[:types]["cx33"])
    assert_equal({ available: %w[fsn1 nbg1], error: nil }, older[:types]["cx33"])
    assert_equal({ available: [], error: nil }, older[:types]["cx23"])
    assert_equal 1, HetznerAvailabilitySample.recent_checks(1).size
  end

end

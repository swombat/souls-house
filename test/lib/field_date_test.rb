require "test_helper"

class FieldDateTest < ActiveSupport::TestCase

  test "a day is midnight in the app's zone" do
    assert_equal Time.zone.local(2019, 3, 14), FieldDate.parse("2019-03-14", param: "dated_at")
  end

  test "a time keeps its offset, and one without an offset is in the app's zone" do
    assert_equal Time.utc(2019, 3, 14, 9, 30), FieldDate.parse("2019-03-14T09:30:00Z", param: "dated_at")
    assert_equal Time.utc(2019, 3, 14, 7, 30), FieldDate.parse("2019-03-14T09:30:00+02:00", param: "dated_at")
    assert_equal Time.utc(2019, 3, 14, 7, 30), FieldDate.parse("2019-03-14T09:30:00+0200", param: "dated_at")
    assert_equal Time.utc(2019, 3, 14, 7, 30), FieldDate.parse("2019-03-14T09:30+02", param: "dated_at")
    assert_equal Time.utc(2019, 3, 14, 14, 0), FieldDate.parse("2019-03-14T09:00:00-05:00", param: "dated_at")
    assert_equal Time.zone.local(2019, 3, 14, 9, 30), FieldDate.parse("2019-03-14T09:30", param: "dated_at")
    assert_equal Rational(1, 2), FieldDate.parse("2019-03-14T09:30:00.5Z", param: "dated_at").subsec
  end

  test "an impossible value is refused, not rolled over or cut back to its day" do
    [
      "2019-03-14T25:99:00Z", "2019-03-14T24:00:00Z", "2019-03-14T09:60:00Z", "2019-03-14T09:30:60Z",
      "2019-03-14T09:30:00+99:99", "2019-03-14T09:30:00+02:60",
      "2019-02-30T12:00:00Z", "2019-02-30", "2019-13-01", "2019-00-10", "2019-03-00",
      "2019-03-14T09:30:00 junk", "2019-03-14 09:30", "14/03/2019", "last tuesday", "2019", "2019-W11-4", ""
    ].each do |value|
      error = assert_raises(FieldDate::Invalid, value) { FieldDate.parse(value, param: "dated_at") }
      assert_match(/\Adated_at must be an ISO 8601 date/, error.message)
    end
  end

  test "parse_or_clear clears on blank" do
    assert_nil FieldDate.parse_or_clear("", param: "dated_at")
    assert_nil FieldDate.parse_or_clear(nil, param: "dated_at")
    assert_raises(FieldDate::Invalid) { FieldDate.parse_or_clear("2019-02-30", param: "dated_at") }
  end

end

require "test_helper"

# The "Needs you" tab (FieldListing) repeats FieldRecordingSpeaker#unnamed?'s
# generic-label test in SQL. A label one side calls generic and the other
# doesn't would show "1 to name" on an item missing from Needs you.
class FieldRecordingSpeakerGenericLabelTest < ActiveSupport::TestCase

  LABELS = [
    "Speaker A", "speaker_0", "SPEAKER-12", "Speaker\tB", "speaker 1", "Speaker ABC",
    "Speaker ABCD", "Ana", "Speakers A", " Speaker A", "Speaker A ", "Speaker",
    "Speaker K", "ſpeaker A", "SpeKker A", "Speaker é", "Speaker A"
  ].freeze

  test "Ruby and PostgreSQL agree on which supplied labels are generic" do
    conn = ActiveRecord::Base.connection
    LABELS.each do |label|
      sql = conn.select_value("SELECT #{conn.quote(label)} ~ #{conn.quote(FieldRecordingSpeaker::GENERIC_LABEL_SQL)}")
      assert_equal label.match?(FieldRecordingSpeaker::GENERIC_LABEL), sql, "disagree on #{label.inspect}"
    end
    assert "Speaker A".match?(FieldRecordingSpeaker::GENERIC_LABEL)
    assert_not "ſpeaker A".match?(FieldRecordingSpeaker::GENERIC_LABEL), "only ASCII spells speaker"
    assert_not "Speaker K".match?(FieldRecordingSpeaker::GENERIC_LABEL)
  end

end

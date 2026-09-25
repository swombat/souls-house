require "test_helper"

class AgentBookmarkTest < ActiveSupport::TestCase

  test "filters note values from request logs and model inspection" do
    note = "A private reason to return"
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal "[FILTERED]", filter.filter({ "note" => note })["note"]
    assert_not_includes AgentBookmark.new(note: note).inspect, note
  end

end

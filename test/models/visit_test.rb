require "test_helper"

class VisitTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
  end

  test "encrypts visit_token and never exposes it in as_json" do
    visit = @agent.visits.create!(
      visited_origin: "https://other.souls.house",
      visited_house_name: "Other House",
      visited_account_name: "Nexus",
      local_name: "Reed",
      visit_token: "vst_super_secret_token_123"
    )

    assert_equal "vst_super_secret_token_123", visit.visit_token
    refute_equal "vst_super_secret_token_123", visit.ciphertext_for(:visit_token)
    refute visit.as_json.key?(:visit_token)
    refute visit.as_json.key?("visit_token")
    refute_includes visit.as_json.to_json, "vst_super_secret_token_123"
  end

  test "validates visited_origin and max_wakes_per_hour" do
    visit = @agent.visits.new(visited_origin: "ftp://bad.example", visit_token: "tok")
    assert_not visit.valid?
    assert visit.errors[:visited_origin].any?

    visit.visited_origin = "https://other.souls.house"
    visit.max_wakes_per_hour = 0
    assert_not visit.valid?
    assert visit.errors[:max_wakes_per_hour].any?
  end

  test "enforces per-visit wake cap and unique remote_wake_id" do
    visit = @agent.visits.create!(
      visited_origin: "https://other.souls.house",
      visit_token: "tok_12345678",
      max_wakes_per_hour: 2
    )

    visit.visit_wakes.create!(remote_wake_id: "w1", remote_conversation_id: "c1")
    assert_not visit.wake_cap_reached?

    dup = visit.visit_wakes.new(remote_wake_id: "w1", remote_conversation_id: "c1")
    assert_not dup.valid?

    visit.visit_wakes.create!(remote_wake_id: "w2", remote_conversation_id: "c1")
    assert visit.wake_cap_reached?
  end

end

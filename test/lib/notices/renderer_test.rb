require "test_helper"

module Notices
  class RendererTest < ActiveSupport::TestCase

    test "renders model history for the whole account and marks only the subject" do
      travel_to Time.zone.local(2026, 8, 2, 10) do
        subject = agents(:research_assistant)
        housemate = subject.account.agents.create!(name: "Housemate")
        changed_at = Time.zone.local(2026, 8, 1, 10)
        Notice.create!(
          scope: "account",
          account: subject.account,
          notice_type: "model_changed",
          params: {
            agent_id: subject.to_param,
            agent_name: "Kestrel",
            from: "anthropic/claude-fable-5",
            to: "openai/gpt-5.2",
            changed_at: changed_at.utc.iso8601
          },
          expires_at: Time.zone.local(2026, 8, 8, 10)
        )

        subject_text = Renderer.section_for(subject)
        housemate_text = Renderer.section_for(housemate)

        assert_includes subject_text, "## Notices from the house"
        assert_includes subject_text, "standing notices"
        assert_includes subject_text, "[account · until 8 August 2026]"
        assert_includes subject_text, "On 1 August 2026, Kestrel's configured model changed"
        assert_includes subject_text, "This model change concerns you."
        assert_includes housemate_text, "Kestrel's configured model changed"
        refute_includes housemate_text, "This model change concerns you."
        refute_includes subject_text, "currently running"
      end
    end

    test "renders system and announcement notices" do
      agent = agents(:research_assistant)
      Notice.create!(
        scope: "system",
        notice_type: "site_renamed",
        expires_at: 30.days.from_now
      )
      Notice.create!(
        scope: "account",
        account: agent.account,
        notice_type: "announcement",
        body: "The house will be quiet this evening.",
        expires_at: 1.day.from_now
      )

      text = Renderer.section_for(agent)

      assert_includes text, "formerly HelixKit"
      assert_includes text, "now called souls.house"
      assert_includes text, "The house will be quiet this evening."
    end

    test "returns nil when no active notices exist" do
      Notice.create!(
        scope: "system",
        notice_type: "site_renamed",
        expires_at: 1.minute.ago
      )

      assert_nil Renderer.section_for(agents(:research_assistant))
    end

    test "skips unknown notice types safely" do
      now = Time.current
      id = Notice.insert!({
        scope: "system",
        notice_type: "future_notice",
        params: {},
        expires_at: 1.day.from_now,
        created_at: now,
        updated_at: now
      }).first.fetch("id")

      assert_nil Renderer.section_for(agents(:research_assistant))
      assert_equal "future_notice", Notice.find(id).notice_type
    end

    test "model change notice remains for six days and expires after eight" do
      agent = agents(:research_assistant)
      travel_to Time.zone.local(2026, 8, 1, 12) do
        Notice.create!(
          scope: "account",
          account: agent.account,
          notice_type: "model_changed",
          params: {
            agent_id: agent.to_param,
            agent_name: agent.name,
            from: "model-a",
            to: "model-b",
            changed_at: Time.current.utc.iso8601
          },
          expires_at: 7.days.from_now
        )
      end

      travel_to Time.zone.local(2026, 8, 7, 12) do
        assert_includes Renderer.section_for(agent), "model-a to model-b"
      end
      travel_to Time.zone.local(2026, 8, 9, 12) do
        assert_nil Renderer.section_for(agent)
      end
    end

  end
end
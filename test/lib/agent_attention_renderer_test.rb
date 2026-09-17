require "test_helper"

class AgentAttentionRendererTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
  end

  test "renders author-split candidate counts" do
    text = AgentAttentionRenderer.section_for(@agent, feed: feed(
      counts: counts(total: 3, human: 2, resident: 1)
    ))

    assert_includes text, "2 threads currently end with a human message"
    assert_includes text, "1 thread currently ends with another resident's message"
    assert_includes text, "another resident's message."
    assert_includes text, "not an obligation to reply"
    assert_includes text, "GET /api/v1/attention"
  end

  test "renders a checked empty state" do
    text = AgentAttentionRenderer.section_for(@agent, feed: feed(counts: counts))

    assert_includes text, "No current attention candidates were found"
    assert_includes text, "souls.house conversations and Telegram threads"
    refute_includes text, "HelixKit"
  end

  test "renders a partial failure without hiding the successful channel" do
    text = AgentAttentionRenderer.section_for(@agent, feed: feed(
      checked: { helixkit: "ok", telegram: "failed" },
      counts: counts(total: 1, human: 1, helixkit: 1)
    ))

    assert_includes text, "souls.house conversations were checked"
    assert_includes text, "a human message. Telegram status"
    assert_includes text, "Telegram status is unavailable"
    assert_includes text, "do not infer that Telegram is quiet"
  end

  test "renders total failure explicitly" do
    text = AgentAttentionRenderer.section_for(@agent, feed: feed(
      checked: { helixkit: "failed", telegram: "failed" },
      counts: counts
    ))

    assert_includes text, "check failed"
    assert_includes text, "Do not infer"
  end

  test "uses the current house name when only Telegram was checked" do
    text = AgentAttentionRenderer.section_for(@agent, feed: feed(
      checked: { helixkit: "failed", telegram: "ok" },
      counts: counts
    ))

    assert_includes text, "Telegram threads were checked: no current attention candidates were found."
    assert_includes text, "souls.house status is unavailable"
    assert_includes text, "do not infer that souls.house is quiet"
    refute_includes text, "HelixKit"
  end

  test "renders total failure if result rendering itself raises" do
    text = AgentAttentionRenderer.section_for(@agent, feed: {})

    assert_includes text, "check failed"
    assert_includes text, "Do not infer"
  end

  private

  def feed(checked: { helixkit: "ok", telegram: "ok" }, counts:)
    {
      generated_at: "2026-08-01T19:30:00Z",
      checked: checked,
      counts: counts,
      items: []
    }
  end

  def counts(total: 0, helixkit: 0, telegram: 0, human: 0, resident: 0, unknown: 0)
    {
      total: total,
      helixkit: helixkit,
      telegram: telegram,
      by_author_type: { human: human, resident: resident, unknown: unknown }
    }
  end

end

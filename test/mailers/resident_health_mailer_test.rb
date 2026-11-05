require "test_helper"

class ResidentHealthMailerTest < ActionMailer::TestCase

  setup do
    @agent = agents(:research_assistant)
    @owner = @agent.account.owner
    (@owner.profile || @owner.build_profile).update!(timezone: "Madrid")
  end

  test "a house fault asks nothing of the owner and says the fix is ours" do
    mail = ResidentHealthMailer.scheduled_runs_failing(streak("house_provider_refused"))
    text = mail.text_part.body.to_s

    assert_equal [ @owner.email_address ], mail.to
    assert_equal "#{@agent.name}'s scheduled runs are failing", mail.subject
    assert_includes text, "have been failing since 28 October 2026, 03:00 CET"
    assert_includes text, RunFailureNotice::NO_REPLY_CAUSES.fetch("house_provider_refused")
    assert_includes text, "on the house's side, not yours"
    assert_includes text, "tab=interactions"
    assert_not_includes text, "Settings tab"
    assert_not_includes text, "Billing tab"
  end

  test "each owner-side cause gets its own step and link" do
    ResidentHealthMailer::OWNER_STEPS.each do |category, (sentence, place)|
      mail = ResidentHealthMailer.scheduled_runs_failing(streak(category))
      text = mail.text_part.body.to_s
      assert_includes text, sentence % { name: @agent.name }, category
      assert_includes text, place == :billing ? "/billing" : "tab=settings", category
      assert_not_includes text, "on the house's side", category
      assert_includes mail.html_part.body.to_s, "Open it here", category
    end
  end

  test "a category nobody explained reads as the house's and an unknown cause" do
    text = ResidentHealthMailer.scheduled_runs_failing(streak(nil, since: nil)).text_part.body.to_s
    assert_includes text, "#{@agent.name}'s scheduled runs are failing: #{RunFailureNotice::NO_REPLY_CAUSES.fetch('unknown')}"
    assert_includes text, "on the house's side"
  end

  test "the recovery email names the resident and when it completed" do
    opened = streak("runtime_error")
    closed = AuditLog.create!(account: @agent.account, action: ScheduledRunFailureNotice::RECOVERED, auditable: @agent,
      data: { streak_id: opened.id, at: "2026-11-05T09:30:00Z" })
    mail = ResidentHealthMailer.scheduled_runs_completing(opened, closed)

    assert_equal "#{@agent.name}'s scheduled runs are completing again", mail.subject
    assert_includes mail.text_part.body.to_s, "5 November 2026, 10:30 CET"
  end

  private

  def streak(category, since: "2026-10-28T02:00:00Z")
    AuditLog.create!(account: @agent.account, action: ScheduledRunFailureNotice::FAILING, auditable: @agent,
      data: { category: category, since: since, count: 2, emailed: true })
  end

end

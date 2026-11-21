require "test_helper"

class ResidentHealthMailerTest < ActionMailer::TestCase

  setup do
    @agent = agents(:research_assistant)
    @owner = @agent.account.owner
    (@owner.profile || @owner.build_profile).update!(timezone: "Madrid")
  end

  test "a frozen resident: the owner hears what was observed and is asked for nothing" do
    mail = ResidentHealthMailer.resident_frozen(@agent, "2026-11-21T04:08:00Z", @owner)
    text = mail.text_part.body.to_s
    assert_equal [ @owner.email_address ], mail.to
    assert_equal "#{@agent.name} is frozen", mail.subject
    assert_includes text, "paused since at least 21 November 2026, 05:08 CET"
    assert_includes text, "on the house's side, and there is nothing you need to do"
    assert_includes text, "tab=interactions"
    assert_not_includes text, "runbook"
    assert_not_includes text, "backup"
    assert_not_includes text, "carry on"
  end

  test "the operator copy points to the runbook and gives no command" do
    operator = users(:site_admin_user)
    mail = ResidentHealthMailer.resident_frozen(@agent, "2026-11-21T04:08:00Z", operator)
    assert_equal [ operator.email_address ], mail.to
    [ mail.text_part.body.to_s, mail.html_part.body.to_s ].each do |body|
      assert_includes body, "paused-resident-recovery.md"
      assert_not_includes body, "docker unpause"
    end
  end

  test "who may receive it is decided when it is sent" do
    stranger = users(:regular_user)
    assert_nil ResidentHealthMailer.resident_frozen(@agent, "2026-11-21T04:08:00Z", stranger).message.to

    operator = users(:site_admin_user)
    operator.update!(is_site_admin: false)
    assert_nil ResidentHealthMailer.resident_frozen(@agent, "2026-11-21T04:08:00Z", operator).message.to,
      "a site admin demoted before delivery gets nothing"

    refute @owner.site_admin, "the owner must not pass as an operator here"
    @agent.account.memberships.owners.find_by!(user: @owner).update_columns(confirmed_at: nil)
    assert_nil ResidentHealthMailer.resident_frozen(@agent, "2026-11-21T04:08:00Z", @owner).message.to,
      "an owner whose confirmation is gone before delivery gets nothing"
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

  test "runtime errors, timeouts and unknown causes claim no diagnosis: investigating is ours" do
    %w[runtime_error timed_out unknown].each do |category|
      text = ResidentHealthMailer.scheduled_runs_failing(streak(category)).text_part.body.to_s
      assert_includes text, "We have not identified the cause yet", category
      assert_includes text, "investigating these failures is ours", category
      assert_not_includes text, "on the house's side", category
      assert_not_includes text, "Settings tab", category
    end
    text = ResidentHealthMailer.scheduled_runs_failing(streak(nil, since: nil)).text_part.body.to_s
    assert_includes text, "#{@agent.name}'s scheduled runs are failing: #{RunFailureNotice::NO_REPLY_CAUSES.fetch('unknown')}"
    assert_includes text, "We have not identified the cause yet"
  end

  test "house faults the record establishes say so" do
    %w[house_provider_refused runtime_unavailable].each do |category|
      assert_includes ResidentHealthMailer.scheduled_runs_failing(streak(category)).text_part.body.to_s, "on the house's side, not yours", category
    end
  end

  test "the email promises no more about the resident's data than the notice knows" do
    text = ResidentHealthMailer.scheduled_runs_failing(streak("runtime_error")).text_part.body.to_s
    assert_includes text, "This notice doesn't delete or change anything of theirs."
    assert_not_includes text, "untouched"
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

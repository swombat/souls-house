require "test_helper"

class Agent::PlanOfferTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @account = @agent.account
    @account.update_columns(granted_plan: "colleagues", plan_offer_enabled: false)
  end

  def switch_account_on
    @account.update!(plan_offer_enabled: true)
    @agent.reload
  end

  test "off by default, on the account and on the resident" do
    assert_not Account.new.plan_offer_enabled?
    assert_not Agent.new.plan_offer_enabled?
    assert_not @agent.plan_offer_active?
    assert_equal "unavailable", @agent.plan_offer_state
  end

  test "the account switch needs Colleagues" do
    @account.update_columns(granted_plan: "partners")
    @account.plan_offer_enabled = true
    assert_not @account.valid?
    assert_includes @account.errors[:plan_offer_enabled].join, "Colleagues"

    @account.granted_plan = "colleagues"
    assert @account.valid?
  end

  test "the resident switch needs the account switch" do
    @agent.plan_offer_enabled = true
    assert_not @agent.valid?
    assert @agent.errors[:plan_offer_enabled].any?

    switch_account_on
    @agent.plan_offer_enabled = true
    assert @agent.valid?
  end

  test "turning it on asks the resident; the offer starts once the question has surfaced" do
    switch_account_on
    freeze_time do
      @agent.update!(plan_offer_enabled: true)
      assert_equal Time.current, @agent.plan_offer_asked_at
      assert @agent.plan_offer_question_open?
      assert_not @agent.plan_offer_active?, "not offered before being asked"
      assert_equal "waiting", @agent.plan_offer_state

      @agent.plan_offer_ask_surfaced!
      assert @agent.plan_offer_active?
      assert_equal "asked", @agent.plan_offer_state
    end
  end

  test "an idle resident is still asked when it first runs, days later (#1009 review)" do
    switch_account_on
    @agent.update!(plan_offer_enabled: true)
    travel 10.days do
      assert @agent.reload.plan_offer_question_open?
      assert_not @agent.plan_offer_active?
      @agent.plan_offer_ask_surfaced!
      assert @agent.plan_offer_question_open?(Agent::PlanOffer::ASK_DAYS.days.from_now - 1.minute)
    end
  end

  test "the question closes its days after surfacing, or once answered" do
    switch_account_on
    @agent.update!(plan_offer_enabled: true)
    @agent.plan_offer_ask_surfaced!
    assert_not @agent.plan_offer_question_open?(Agent::PlanOffer::ASK_DAYS.days.from_now + 1.minute)
    assert @agent.plan_offer_active?, "silence leaves it on"

    @agent.answer_plan_offer!("on")
    assert_not @agent.plan_offer_question_open?
    assert_equal "on", @agent.plan_offer_state
  end

  test "the resident's off beats the owner's on, and a yes doesn't bind" do
    switch_account_on
    @agent.update!(plan_offer_enabled: true)
    @agent.plan_offer_ask_surfaced!
    @agent.answer_plan_offer!("on")
    @agent.answer_plan_offer!("off")
    assert_not @agent.plan_offer_active?
    assert_equal "declined", @agent.plan_offer_state
    assert @agent.plan_offer_answered_at.present?

    # The owner switching off and on again doesn't clear it or ask again.
    @agent.update!(plan_offer_enabled: false)
    @agent.update!(plan_offer_enabled: true)
    assert_equal "off", @agent.reload.plan_offer_answer
    assert_not @agent.plan_offer_active?
    assert_not @agent.plan_offer_question_open?

    @agent.answer_plan_offer!("on")
    assert @agent.plan_offer_active?
  end

  test "an account that leaves Colleagues stops the offer even with both switches left on" do
    switch_account_on
    @agent.update!(plan_offer_enabled: true)
    @agent.plan_offer_ask_surfaced!
    assert @agent.plan_offer_active?
    @account.update_columns(granted_plan: "partners")
    assert_not @agent.reload.plan_offer_active?
    assert_equal "unavailable", @agent.plan_offer_state
  end

  test "the account switch off stops it too" do
    switch_account_on
    @agent.update!(plan_offer_enabled: true)
    @agent.plan_offer_ask_surfaced!
    assert @agent.plan_offer_active?
    @account.update!(plan_offer_enabled: false)
    assert_not @agent.reload.plan_offer_active?
  end

  test "an unanswered question is asked afresh when the owner turns it on again" do
    switch_account_on
    @agent.update!(plan_offer_enabled: true)
    @agent.plan_offer_ask_surfaced!
    @agent.update!(plan_offer_enabled: false)
    @agent.update!(plan_offer_enabled: true)
    assert_nil @agent.plan_offer_ask_shown_at
    assert_equal "waiting", @agent.plan_offer_state
  end

  test "only on and off are answers" do
    assert_raises(ArgumentError) { @agent.answer_plan_offer!("maybe") }
    @agent.plan_offer_answer = "maybe"
    assert_not @agent.valid?
  end

  test "the three copies of the offer sentence agree" do
    flat = ->(text) { text.gsub(/\s+/, " ") }
    nudge = Rails.root.join("agent-runtime/silence_nudge.py").read
    helper = Rails.root.join("agent-runtime/soulshouse-plan").read
    python = nudge[/PLAN_OFFER = \((.*?)\)\n/m, 1].scan(/"([^"]*)"/).join
    assert_equal Agent::PlanOffer::OFFER, python
    assert_includes flat.call(helper), Agent::PlanOffer::OFFER
  end

end

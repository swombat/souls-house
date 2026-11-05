# Tells an account's owner when a resident's scheduled runs open a failing
# streak, and once more when they complete again (#754). The navbar's black
# count says the same thing to an owner who is signed in; this is for the
# owner who isn't. Five residents had open streaks on 5 Nov 2026 and none of
# their owners had been back since the count appeared.
#
# One email per streak: sent only from ScheduledRunFailureNotice#failing!,
# right after the streak's audit row is written, and the row is the latch.
# The recovery email goes only where a failing email went (the row's
# `emailed`), so nobody is told a thing has stopped that they were never
# told had started.
#
# When the cause is on the house's side, the email says so and asks nothing
# of the owner (Mira's amendment in eKnXDY): a step for the owner is offered
# only when the owner can actually take it.
class ResidentHealthMailer < ApplicationMailer

  # What the owner can do, per owner-side category: one sentence and where
  # to do it. Every other category is the house's to fix.
  OWNER_STEPS = {
    "needs_setup" => [ "Give %{name} a working key or connect a subscription in their Settings tab.", :settings ],
    "house_allowance_exhausted" => [ "Add to %{name}'s allowance from the account's Billing tab, or wait for next month's.", :billing ],
    "house_allowance_none" => [ "Choose a plan that includes a house-model allowance in the Billing tab, or give %{name} their own key in Settings.", :billing ],
    "authentication_error" => [ "Check the key, or reconnect the subscription, in %{name}'s Settings tab.", :settings ],
    "subscription_limit" => [ "Runs should complete again when the subscription's limit resets. To use a different subscription or a key, open %{name}'s Settings tab.", :settings ],
    "model_unavailable" => [ "Choose a model their subscription includes in %{name}'s Settings tab.", :settings ]
  }.freeze

  def self.owner_side?(category) = OWNER_STEPS.key?(category)

  def scheduled_runs_failing(streak)
    load(streak)
    data = streak.data || {}
    @category = data["category"].presence || "unknown"
    @cause = RunFailureNotice::NO_REPLY_CAUSES.fetch(@category, RunFailureNotice::NO_REPLY_CAUSES.fetch("unknown"))
    @since = format_time(data["since"])
    @count = data["count"].to_i
    if (step = OWNER_STEPS[@category])
      @step = step.first % { name: @agent.name }
      @step_url = step.last == :billing ? account_billing_url(@account) : edit_account_agent_url(@account, @agent, tab: "settings")
    end
    mail(to: @owner.email_address, subject: "#{@agent.name}'s scheduled runs are failing")
  end

  def scheduled_runs_completing(streak, recovery)
    load(streak)
    @since = format_time(streak.data&.dig("since"))
    @at = format_time(recovery.data&.dig("at"))
    mail(to: @owner.email_address, subject: "#{@agent.name}'s scheduled runs are completing again")
  end

  private

  def load(streak)
    @agent = streak.auditable
    @account = @agent.account
    @owner = @account.owner
    @runs_url = edit_account_agent_url(@account, @agent, tab: "interactions")
  end

  def format_time(value)
    return if value.blank?

    zone = ActiveSupport::TimeZone[@owner&.timezone.to_s] || ActiveSupport::TimeZone["UTC"]
    Time.iso8601(value).in_time_zone(zone).strftime("%-d %B %Y, %H:%M %Z")
  end

end

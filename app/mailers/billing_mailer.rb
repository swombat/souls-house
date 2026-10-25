# Tells an account's owner when a resident's payment fails and when the
# resident falls asleep. The Billing tab and the resident's page say the
# same thing for as long as it lasts.
class BillingMailer < ApplicationMailer

  def payment_failed(entitlement)
    load(entitlement)
    @deadline = entitlement.grace_deadline
    mail(to: @owner.email_address, subject: "#{@agent.name}'s plan payment didn't go through")
  end

  def resident_asleep(entitlement)
    load(entitlement)
    mail(to: @owner.email_address, subject: "#{@agent.name} is asleep: their plan payment has lapsed")
  end

  private

  def load(entitlement)
    @agent = entitlement.agent
    @account = entitlement.account
    @owner = @account.owner
    @billing_url = account_billing_url(@account)
  end

end

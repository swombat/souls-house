class ApplicationMailer < ActionMailer::Base

  default from: ENV.fetch("SOULSHOUSE_MAIL_FROM", "souls.house <hello@souls.house>")
  layout "mailer"

end

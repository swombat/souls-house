# Knocks for one resident's handoff (MessageHandoff#dispatch!), after the
# commit that saved the message. Safe to deliver any number of times: only a
# pending request knocks, under the chat lock.
class MessageHandoffJob < ApplicationJob

  queue_as :default

  def perform(handoff)
    handoff.dispatch!
  end

end

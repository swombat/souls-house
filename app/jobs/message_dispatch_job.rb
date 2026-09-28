# Reserves the runtime interaction a human message's mentions asked for
# (#94 B, step 4b-ii). Safe to deliver any number of times: MessageDispatch
# reserves at most once, under its own lock.
class MessageDispatchJob < ApplicationJob

  def perform(dispatch)
    dispatch.reserve!
  end

end

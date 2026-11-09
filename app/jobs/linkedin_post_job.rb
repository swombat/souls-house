# Sends a LinkedIn post that carries an image or a video (LinkedinPoster).
# Never retried: a second run could publish twice. A run that dies leaves the
# post pending, and after LinkedinPost::PENDING_RESOLVABLE_AFTER with no
# activity it can be resolved like an unknown one.
class LinkedinPostJob < ApplicationJob

  queue_as :default
  discard_on ActiveJob::DeserializationError

  def perform(post)
    LinkedinPoster.deliver!(post)
  end

end

# Sends an X post that carries an image or a video (XPoster). Never retried:
# a second run could publish twice. A run that dies leaves the post pending,
# and after TweetLog::MEDIA_PENDING_RESOLVABLE_AFTER with no activity it can
# be resolved like an unknown one.
class XPostJob < ApplicationJob

  queue_as :default
  discard_on ActiveJob::DeserializationError

  def perform(log)
    XPoster.deliver!(log)
  end

end

# The effects of one fulfilment of a watch, each recorded once it happens:
# the posted message (message_id) and each resident's wake (woken). The
# deliver job checks these before acting, so a retry after any partial
# success neither posts nor wakes twice. v1 keys by the watch (one-shot); a
# recurring watch would key by run id and attempt.
class RepositoryWatchDelivery < ApplicationRecord

  belongs_to :repository_watch
  belongs_to :message, optional: true

  def woken?(agent_id)
    woken.to_h.key?(agent_id.to_s)
  end

  def completed?
    completed_at.present?
  end

end

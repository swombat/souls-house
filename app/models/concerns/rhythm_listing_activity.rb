# Only a real quiet/listed transition invalidates rhythm readers. Chat touches
# from ordinary conversation traffic must not refresh their history.
module RhythmListingActivity

  extend ActiveSupport::Concern

  included do
    before_save :capture_rhythm_listing_activity
    before_destroy :capture_rhythm_listing_activity
  end

  private

  def capture_rhythm_listing_activity
    # Assistant streaming/token updates cannot affect the listing predicate.
    return if is_a?(Message) && role != "user" && !will_save_change_to_role?

    target = is_a?(ReplyExpectation) ? message&.chat : chat
    return unless target&.persisted? && target.rhythm_run?

    was_quiet = target.quiet_rhythm_run?
    # Capture per producing transaction, not on the model instance: a later
    # save or rolled-back savepoint must not erase an earlier real transition.
    ActiveRecord.after_all_transactions_commit do
      if Chat.exists?(target.id) && target.quiet_rhythm_run? != was_quiet
        RhythmActivity.broadcast_for(target.account)
      end
    end
  end

end

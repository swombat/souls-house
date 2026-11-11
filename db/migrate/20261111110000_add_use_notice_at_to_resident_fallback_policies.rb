# #690 slice C. use_notice_at: when the owner was last told that a resident
# started spending on its paid fallback (once per cap period, and again after
# it is turned off and on, which clears it). paid_fallback_interaction_id: the
# live fallback run a resident's post was made during, for a post not linked
# to a run of that conversation, so the reply is labelled wherever it lands.
class AddUseNoticeAtToResidentFallbackPolicies < ActiveRecord::Migration[8.1]

  def change
    add_column :resident_fallback_policies, :use_notice_at, :datetime
    add_column :messages, :paid_fallback_interaction_id, :bigint
  end

end

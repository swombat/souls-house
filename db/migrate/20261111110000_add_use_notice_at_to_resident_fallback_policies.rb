# #690 slice C. use_notice_period_start: the cap period (by the paid call's
# admission time) the owner was last told about, once per period, cleared when
# the fallback is turned off and on; use_notice_at: when that email was queued,
# for display. paid_fallback_interaction_id: the
# live fallback run a resident's post was made during, for a post not linked
# to a run of that conversation, so the reply is labelled wherever it lands.
class AddUseNoticeAtToResidentFallbackPolicies < ActiveRecord::Migration[8.1]

  def change
    add_column :resident_fallback_policies, :use_notice_at, :datetime
    add_column :resident_fallback_policies, :use_notice_period_start, :datetime
    add_column :messages, :paid_fallback_interaction_id, :bigint
  end

end

# A narrow invalidation for Field readers, not the account's chat traffic.
# The marker carries no item content; clients refetch their mapped props.
module FieldActivityBroadcasting

  extend ActiveSupport::Concern

  included do
    # Items already call the broadcast methods after commit, and derived-data
    # writers call broadcast_refresh explicitly. Tags have no record streams.
    unless self < Broadcastable
      after_commit :broadcast_field_activity, on: [ :create, :update, :destroy ]
    end
  end

  private

  def broadcast_refresh
    super if defined?(super)
    broadcast_field_activity
  end

  def broadcast_removal
    super if defined?(super)
    broadcast_field_activity
  end

  def broadcast_field_activity
    return if respond_to?(:skip_broadcast) && skip_broadcast
    return unless account

    ActionCable.server.broadcast("FieldActivity:#{account.obfuscated_id}", { action: "refresh" })
  end

end

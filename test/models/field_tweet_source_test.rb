require "test_helper"
require "support/field_tweet_helpers"

class FieldTweetSourceTest < ActiveSupport::TestCase

  include FieldTweetHelpers
  include ActiveJob::TestHelper

  setup do
    @account = accounts(:team_account)
    @source = @account.all_field_tweet_sources.create!(handle: "example", created_by: users(:user_1))
    @admin = users(:site_admin_user)
    @account.memberships.create!(user: @admin, role: "member", skip_confirmation: true)
  end

  test "removal releases only the current slot and keeps source history and provenance" do
    attrs = FieldTweet.attributes_from(tweet_payload(1, at: Time.current), fetched_at: Time.current)
    tweet = @account.field_tweets.create!(attrs.merge(field_tweet_source: @source))
    backlog = @source.backlog_items.create!(provider_tweet_id: "2", posted_at: Time.current, attrs: attrs.merge(provider_tweet_id: "2"))
    @source.update!(window_since: Time.current - 1.hour, window_until: Time.current, window_cursor: "saved")
    saved = @source.attributes.except("removed_at", "state", "next_attempt_at", "updated_at")

    @source.remove!
    assert_nil @account.reload.field_tweet_source
    assert_equal saved, @source.reload.attributes.slice(*saved.keys)
    assert_equal @source.id, tweet.reload.field_tweet_source_id
    assert @source.backlog_items.exists?(backlog.id)
    assert_equal users(:user_1), @source.created_by

    replacement = @account.all_field_tweet_sources.create!(handle: "next")
    assert_equal replacement, @account.reload.field_tweet_source
    assert_equal 2, @account.all_field_tweet_sources.count
    assert_not @account.all_field_tweet_sources.new(handle: "third").valid?
  end

  test "recovery requires an account scoped system administrator and stays paused" do
    @source.remove!
    assert_raises(ActiveRecord::RecordNotFound) { @source.restore!(account: @account, actor: users(:user_1)) }
    assert_raises(ActiveRecord::RecordNotFound) { @source.restore!(account: accounts(:another_team), actor: @admin) }
    @account.memberships.find_by!(user: @admin).destroy!
    assert_raises(ActiveRecord::RecordNotFound) { @source.restore!(account: @account, actor: @admin) }
    @account.memberships.create!(user: @admin, role: "member", skip_confirmation: true)

    assert_no_enqueued_jobs { @source.restore!(account: @account, actor: @admin) }
    assert_nil @source.reload.removed_at
    assert_equal "paused", @source.state
    assert_nil @source.next_attempt_at
    FieldTweets.integration_changed!(@account)
    assert_equal "paused", @source.reload.state
  end

  test "recovery refuses an occupied slot or unfinished collection" do
    @source.remove!
    replacement = @account.all_field_tweet_sources.create!(handle: "next")
    assert_raises(ActiveRecord::RecordInvalid) { @source.restore!(account: @account, actor: @admin) }
    assert @source.reload.removed?
    replacement.remove!

    @source.update!(sync_claimed_at: Time.current)
    assert_raises(ActiveRecord::RecordInvalid) { @source.restore!(account: @account, actor: @admin) }
    @source.reload.update!(sync_claimed_at: nil)
    call = FieldTweetCall.create!(account: @account, field_tweet_source: @source, funding: "house", status: "reserved", charge_usd: 0)
    assert_raises(ActiveRecord::RecordInvalid) { @source.restore!(account: @account, actor: @admin) }
    call.release!
    @source.reload.restore!(account: @account, actor: @admin)
    assert_equal "paused", @source.reload.state
  end

  test "database live slot uniqueness cannot be bypassed by skipping validation" do
    duplicate = @account.all_field_tweet_sources.new(handle: "other", connected_at: Time.current, checkpoint_at: Time.current)
    assert_raises(ActiveRecord::RecordNotUnique) do
      FieldTweetSource.transaction(requires_new: true) { duplicate.save!(validate: false) }
    end
    @source.remove!
    @account.all_field_tweet_sources.create!(handle: "other")
    assert_raises(ActiveRecord::RecordNotUnique) do
      FieldTweetSource.transaction(requires_new: true) { @source.update_columns(removed_at: nil) }
    end
  end

  test "stale resume funding jobs and due queries cannot collect a removed source" do
    stale = FieldTweetSource.find(@source.id)
    @source.remove!
    assert_raises(ActiveRecord::RecordNotFound) { stale.resume! }
    FieldTweets.integration_changed!(@account)
    assert_not FieldTweets::Sync.due.exists?(@source.id)
    FieldTweets::Sync.stub(:new, ->(*) { flunk "removed job reached collection" }) do
      FieldTweets::SyncJob.perform_now(@source.id)
    end
    assert @source.reload.removed?
    assert_equal "paused", @source.state
    assert_nil @source.next_attempt_at
  end

  test "account owner cascade includes removed and current source histories" do
    account = Account.create!(name: "Tweet cascade", account_type: "team")
    old = account.all_field_tweet_sources.create!(handle: "old")
    old.remove!
    current = account.all_field_tweet_sources.create!(handle: "current")
    item = old.backlog_items.create!(provider_tweet_id: "1", posted_at: Time.current, attrs: {})
    account.destroy!
    assert_not FieldTweetSource.exists?(old.id)
    assert_not FieldTweetSource.exists?(current.id)
    assert_not FieldTweetBacklogItem.exists?(item.id)
  end

end

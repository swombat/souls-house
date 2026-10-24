# The account's tweet stream: which public handle it follows and what is
# included. Account managers only: it spends money. The key that pays is the
# account's TwitterAPI.io integration (Settings → Integrations), or the
# house's for accounts granted it; following needs one of the two.
class FieldTweetSourcesController < ApplicationController

  require_feature_enabled :agents
  before_action :require_account_manager!
  before_action :require_streams_enabled
  before_action :set_source, except: :create

  def create
    return back(alert: "#{FieldTweets::NO_FUNDING}.") if FieldTweets.funding_for(current_account).nil?

    source = current_account.build_field_tweet_source(source_params.merge(created_by: Current.user))
    if source.save
      FieldTweets::SyncJob.perform_later(source.id)
      back notice: "Following @#{source.handle}. Posts from now on will come into the Field."
    else
      back alert: source.errors.full_messages.to_sentence
    end
  end

  # handle can't change: following someone else is removing and adding, so
  # one handle's window never carries over to another.
  def update
    if @source.update(source_params.except(:handle))
      back notice: "Saved."
    else
      back alert: @source.errors.full_messages.to_sentence
    end
  end

  # The tweets already brought in stay in the Field.
  def destroy
    handle = @source.handle
    @source.destroy!
    back notice: "Stopped following @#{handle}. Tweets already in the Field stay."
  end

  def pause
    @source.pause!("Paused by #{Current.user.full_name.presence || "a member"}")
    back notice: "Paused."
  end

  def resume
    @source.resume!
    FieldTweets::SyncJob.perform_later(@source.id)
    back notice: "Resumed. Collection picks up where it stopped."
  end

  private

  def set_source
    @source = current_account.field_tweet_source or raise ActiveRecord::RecordNotFound
  end

  def require_streams_enabled
    raise ActiveRecord::RecordNotFound unless FieldTweets.enabled?
  end

  def source_params
    params.require(:field_tweet_source).permit(:handle, :include_replies, :include_quotes, :include_reposts, :own_monthly_usd_limit)
  end

  def back(**flash)
    redirect_to account_field_path(current_account, tab: "tweets"), **flash
  end

end

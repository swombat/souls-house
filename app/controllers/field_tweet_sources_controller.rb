# The account's tweet stream: which public handle it follows, what is
# included, and whose TwitterAPI.io key pays. Account managers only: it
# spends money and may hold a key.
#
# The key is write-only. It can be set, replaced or removed here and is never
# sent back to any page or API (FieldTweetSource#status_json says only
# whether there is one).
class FieldTweetSourcesController < ApplicationController

  require_feature_enabled :agents
  before_action :require_account_manager!
  before_action :require_streams_enabled
  before_action :set_source, except: :create

  def create
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
    attributes = source_params.except(:handle)
    attributes[:api_key] = nil if params.dig(:field_tweet_source, :remove_api_key).to_s == "true"
    key_changed = attributes.key?(:api_key)
    if @source.update(attributes)
      # A new key is a new chance: a source stopped for its old key resumes.
      @source.resume! if key_changed && @source.state == "needs_attention"
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
    attributes = params.require(:field_tweet_source).permit(:handle, :include_replies, :include_quotes, :include_reposts, :api_key, :own_monthly_usd_limit)
    # An empty key field means "leave it as it is", not "remove it".
    attributes.delete(:api_key) if attributes[:api_key].blank?
    attributes
  end

  def back(**flash)
    redirect_to account_field_path(current_account, tab: "tweets"), **flash
  end

end

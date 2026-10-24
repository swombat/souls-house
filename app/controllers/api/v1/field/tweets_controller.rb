module Api
  module V1
    module Field
      # Tweets in the key's home account's Field, brought in by its tweet
      # stream (FieldTweetSource). Read-only for residents; a person may
      # delete one (it stays deleted: the next poll won't bring it back).
      #
      #   GET /api/v1/field/tweets?tag=thread&page=0
      #   GET /api/v1/field/tweets/:id
      #   GET /api/v1/field/tweet_stream     what is followed and how collection stands
      class TweetsController < BaseController

        include ApiHumanReach
        include ApiHomeAccountOnly
        include FieldTagsJson

        PAGE_SIZE = 50

        before_action :require_human_actor!, only: :destroy
        require_api_feature_enabled :agents, only: :destroy

        def index
          return unless (tags = tag_params)

          page = params[:page].to_s.match?(/\A\d+\z/) ? params[:page].to_i : 0
          tweets = with_all_tags(current_api_account.field_tweets.kept, tags)
            .newest_first.offset(page * PAGE_SIZE).limit(PAGE_SIZE + 1).to_a
          more = tweets.size > PAGE_SIZE
          tweets = tweets.first(PAGE_SIZE)
          names = FieldTagging.names_for(tweets)
          render json: { tweets: tweets.map { |tweet| tweet_json(tweet, names[[ "FieldTweet", tweet.id ]] || []) },
                         page: page, next_page: (page + 1 if more) }
        end

        def show
          tweet = current_api_account.field_tweets.kept.find(params[:id])
          render json: { tweet: tweet_json(tweet, tweet.tag_names) }
        end

        def destroy
          tweet = find_human_record!(FieldTweet.kept, params[:id])
          tweet.discard!
          head :no_content
        end

        def stream
          source = current_api_account.field_tweet_source
          render json: { enabled: FieldTweets.enabled?, funding: FieldTweets.funding_for(current_api_account), source: source&.status_json }
        end

        private

        def tweet_json(tweet, tags)
          FieldItems.tweet_json(tweet, tags).except(:key, :kind).merge(
            api_path: api_v1_field_tweet_path(tweet)
          )
        end

      end
    end
  end
end

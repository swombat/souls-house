# Deleting a tweet from the Field page. Any member, like files. The row is
# discarded, not removed, so the stream won't bring it back.
class FieldTweetsController < ApplicationController

  require_feature_enabled :agents

  def destroy
    current_account.field_tweets.kept.find(params[:id]).discard!
    redirect_to account_field_path(current_account, tab: "tweets"), notice: "Deleted from the Field. It won't be brought back."
  end

end

# X posts with an image or a video, and long posts.
#
# x_integrations.granted_scopes: the scopes X says it granted, from the
# token response's `scope` field (never what the house asked for). A grant
# made before media.write was requested has none recorded, and media posting
# asks the owner to reconnect.
#
# tweet_logs: the media a post carries (the file itself is an Active Storage
# attachment until the post finishes), X's media id once uploaded, and the
# integration's app_generation the post was reserved under, so a post never
# goes out through a connection made after it was asked for.
class AddMediaAndScopesToXPosting < ActiveRecord::Migration[8.1]

  def change
    add_column :x_integrations, :granted_scopes, :string

    add_column :tweet_logs, :media_kind, :string
    add_column :tweet_logs, :media_filename, :string
    add_column :tweet_logs, :media_id, :string
    add_column :tweet_logs, :x_app_generation, :integer
  end

end

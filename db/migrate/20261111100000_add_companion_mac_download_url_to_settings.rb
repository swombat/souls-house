# Where the companion app's Mac download lives (#companion page, eQwVPJ).
# Blank means there is no signed, notarised build yet, and every download
# control reads "Mac download coming soon" instead of linking a file people
# can't open. A site admin fills it in from Site Admin once one exists.
class AddCompanionMacDownloadUrlToSettings < ActiveRecord::Migration[8.1]

  def change
    add_column :settings, :companion_mac_download_url, :string, limit: 500
  end

end
